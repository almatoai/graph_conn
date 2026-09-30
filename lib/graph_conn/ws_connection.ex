defmodule GraphConn.WsConnection do
  @moduledoc false

  use GenServer
  alias GraphConn.{ClientHello, ConnectionManager, Instrumenter, Request, WS}
  require Logger

  # Well above any limit a server advertises for its own inbound frames, which it relays onwards.
  @default_max_frame_bytes 16_777_216

  defmodule State do
    @moduledoc false

    @type t() :: %__MODULE__{
            base_name: atom(),
            api: atom(),
            internal_state: map(),
            status: GraphConn.status(),
            last_pong: DateTime.t(),
            ws_ping: [
              interval_in_ms: pos_integer(),
              reconnect_after_missing_pings: pos_integer()
            ],
            conn_pid: nil | pid(),
            tunnel_ref: nil | reference(),
            stream_ref: nil | reference(),
            client_hello: nil | map(),
            token_requests: %{(request_id :: String.t()) => true}
          }

    @enforce_keys ~w(base_name api internal_state status last_pong ws_ping)a
    defstruct @enforce_keys ++
                ~w(conn_pid tunnel_ref stream_ref client_hello)a ++ [token_requests: %{}]
  end

  defp _name(base_name, api) do
    base_name
    |> Module.concat(api)
    |> Module.concat(WsConnection)
  end

  @doc false
  @spec child_spec(opts :: [term()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, opts},
      type: :worker,
      restart: :temporary
    }
  end

  @doc false
  @spec start_link(
          base_name :: atom(),
          api :: atom(),
          config :: Keyword.t(),
          internal_state :: map(),
          version :: map(),
          token :: String.t()
        ) :: GenServer.on_start()
  def start_link(base_name, api, config, internal_state, version, token) do
    GenServer.start_link(__MODULE__, {base_name, api, config, internal_state, version, token},
      name: _name(base_name, api)
    )
  end

  @doc false
  @spec execute(server :: GenServer.server(), Request.t()) :: :ok
  def execute(server, %Request{} = request),
    do: GenServer.cast(server, {:execute, request})

  @doc false
  @spec update_token(server :: GenServer.server(), token :: String.t()) :: :ok
  def update_token(server, token),
    do: GenServer.cast(server, {:update_token, token})

  @impl GenServer
  def init({base_name, api, config, internal_state, version, token}) do
    status = {:disconnected, :started}
    path = "#{version.path}?#{_url_params(config)}"

    state =
      %State{
        base_name: base_name,
        api: api,
        internal_state: internal_state,
        status: status,
        ws_ping: Keyword.get(config, :ws_ping, _default_ping_config()),
        last_pong: DateTime.utc_now(),
        client_hello: _client_hello(api, config)
      }
      |> _connect(config)

    state
    |> _ws_upgrade(path, version.subprotocol, token, _max_frame_bytes(config))
    |> case do
      {:ok, %State{} = upgraded} -> {:ok, upgraded}
      {:stop, reason} -> {:stop, reason}
    end
  end

  # Only the action API knows `clientHello`.
  defp _client_hello(:"action-ws", config),
    do: ClientHello.frame(config)

  defp _client_hello(_api, _config),
    do: nil

  defp _url_params(config) do
    config
    |> Keyword.get(:url_params, %{})
    |> URI.encode_query()
  end

  defp _default_ping_config do
    [
      interval_in_ms: 2_000,
      reconnect_after_missing_pings: 3
    ]
  end

  @impl GenServer
  def handle_cast({:execute, %Request{} = request}, %State{} = state) do
    spawn(fn ->
      Logger.debug(fn ->
        "[WsConnection] Pushing message to #{state.api}:\n#{inspect(request.body)}"
      end)

      WS.push(state.conn_pid, state.stream_ref, Jason.encode!(request.body))
    end)

    {:noreply, state}
  end

  def handle_cast({:update_token, token}, %State{} = state) do
    request_id = UUID.uuid4()
    Logger.info("[WsConnection] Sending #{state.api} the refreshed token")

    WS.push(
      state.conn_pid,
      state.stream_ref,
      Jason.encode!(_token_frame(state.api, token, request_id))
    )

    {:noreply, _await_token_answer(state, request_id)}
  end

  @impl GenServer
  def handle_info(
        {:gun_ws, conn_pid, _stream_ref, {:text, text}},
        %State{conn_pid: conn_pid} = state
      ) do
    ws_connection = self()

    spawn(fn ->
      :ok =
        Instrumenter.execute(
          :ws_received_bytes,
          %{time: DateTime.utc_now(), bytes: byte_size(text)},
          %{node: Node.self()}
        )

      msg = Jason.decode!(text)

      Logger.debug(fn ->
        "[WsConnection] Just received text message on #{state.api}:\n#{inspect(msg)}"
      end)

      _handle_message(msg, state, ws_connection)
    end)

    {:noreply, state}
  end

  def handle_info(
        {:gun_ws, conn_pid, _stream_ref, :ping},
        %State{conn_pid: conn_pid} = state
      ) do
    Logger.debug("[WsConnection] Ignore received ping, gun will send pong")
    {:noreply, state}
  end

  def handle_info(
        {:gun_ws, conn_pid, _stream_ref, :pong},
        %State{conn_pid: conn_pid} = state
      ) do
    Logger.debug("[WsConnection] Received pong")
    {:noreply, %{state | last_pong: DateTime.utc_now()}}
  end

  def handle_info(:send_ping, %State{} = state) do
    Logger.debug("[WsConnection] Sending ping")

    WS.ping(state.conn_pid, state.stream_ref)
    Process.send_after(self(), :send_ping, Keyword.get(state.ws_ping, :interval_in_ms))
    {:noreply, state}
  end

  def handle_info(:check_last_pong, %State{} = state) do
    Logger.debug("[WsConnection] checking last pong")

    reconnect_after =
      (Keyword.get(state.ws_ping, :interval_in_ms) *
         Keyword.get(state.ws_ping, :reconnect_after_missing_pings))
      |> Integer.floor_div(1000)

    DateTime.utc_now()
    |> DateTime.diff(state.last_pong)
    |> case do
      diff when diff > reconnect_after ->
        Instrumenter.execute(
          :ws_lost_connection,
          %{time: DateTime.utc_now()},
          %{node: Node.self()}
        )

        {:stop, {:error, "Missing pong for more than #{reconnect_after} seconds"}, state}

      _ ->
        Process.send_after(self(), :check_last_pong, Keyword.get(state.ws_ping, :interval_in_ms))
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _, :process, conn_pid, reason}, %State{conn_pid: conn_pid} = state) do
    status =
      case reason do
        :shutdown ->
          Logger.info("WS connection with #{state.api} went down normally.")
          {:disconnected, :normal}

        _ ->
          :ok =
            Instrumenter.execute(
              :ws_down,
              %{time: DateTime.utc_now()},
              %{node: Node.self()}
            )

          Logger.warning("WS connection with #{state.api} went down: #{inspect(reason)}")
          {:disconnected, reason}
      end

    {:stop, status, state}
  end

  def handle_info({:hello, hello}, %State{} = state) do
    max_frame_bytes = _advertised_max_frame_bytes(hello)
    :ok = ConnectionManager.hello_received(state.base_name, self(), max_frame_bytes)
    _send_client_hello(state)

    {:noreply, state}
  end

  def handle_info({:token_answered, request_id, answer}, %State{} = state) do
    _log_token_answer(state.api, answer)
    {:noreply, %State{state | token_requests: Map.delete(state.token_requests, request_id)}}
  end

  def handle_info({:gun_ws, _, _, :close}, %State{} = state) do
    {:stop, "server sent close request", state}
  end

  # A policy close refuses the token itself, so the reason has to survive as something
  # `ConnectionManager` can tell apart from an ordinary drop. Wrapped in `{:disconnected, _}`
  # because consumers match on that shape; a bare tuple reaches their catch-all instead.
  def handle_info({:gun_ws, _, _, {:close, 1008, msg}}, %State{} = state) do
    {:stop, {:disconnected, {:rejected_by_server, msg}}, state}
  end

  # A normal or going-away close is the server ending the socket on purpose, a rolling restart
  # say, so it stops as a shutdown rather than as a crash.
  def handle_info({:gun_ws, _, _, {:close, code, msg}}, %State{} = state)
      when code in [1000, 1001] do
    {:stop, {:shutdown, "server sent close request: #{msg}"}, state}
  end

  def handle_info({:gun_ws, _, _, {:close, _code, msg}}, %State{} = state) do
    {:stop, "server sent close request: #{msg}", state}
  end

  def handle_info({:gun_down, _, _, :closed, _}, %State{} = state) do
    {:stop, "WS connection went down", state}
  end

  def handle_info(message, %State{} = state) do
    Logger.debug(fn -> "Unexpected message: #{inspect(message)} on state: #{inspect(state)}" end)
    {:noreply, state}
  end

  defp _handle_message(%{"type" => "hello"} = msg, _state, ws_connection) do
    Logger.info("[WsConnection] Received hello message: #{inspect(msg)}")
    send(ws_connection, {:hello, msg})
  end

  defp _handle_message(%{"id" => request_id} = answer, %State{} = state, ws_connection)
       when is_map_key(state.token_requests, request_id),
       do: send(ws_connection, {:token_answered, request_id, answer})

  defp _handle_message(%{} = msg, state, _ws_connection),
    do: apply(state.base_name, :handle_message, [state.api, msg, state.internal_state])

  defp _token_frame(:"events-ws", token, _request_id),
    do: %{type: "token", args: %{_TOKEN: token}}

  defp _token_frame(:"graph-ws", token, request_id),
    do: %{id: request_id, type: "token", _TOKEN: token}

  # Only graph-ws answers, so only its request is held until the answer is dropped.
  defp _await_token_answer(%State{api: :"graph-ws"} = state, request_id),
    do: %State{state | token_requests: Map.put(state.token_requests, request_id, true)}

  defp _await_token_answer(%State{} = state, _request_id),
    do: state

  defp _log_token_answer(api, %{"body" => "ok"}),
    do: Logger.info("[WsConnection] #{api} took the refreshed token")

  defp _log_token_answer(api, answer),
    do: Logger.warning("[WsConnection] #{api} refused the refreshed token: #{inspect(answer)}")

  defp _advertised_max_frame_bytes(%{"max_frame_bytes" => max_frame_bytes})
       when is_integer(max_frame_bytes) and max_frame_bytes > 0,
       do: max_frame_bytes

  defp _advertised_max_frame_bytes(_hello),
    do: nil

  defp _send_client_hello(%State{client_hello: nil}),
    do: :ok

  defp _send_client_hello(%State{client_hello: client_hello} = state) do
    Logger.info("[WsConnection] Sending clientHello: #{inspect(client_hello)}")
    WS.push(state.conn_pid, state.stream_ref, Jason.encode!(client_hello))
  end

  ## Helper functions

  @spec _connect(State.t(), config :: Keyword.t()) :: State.t()
  defp _connect(%State{} = state, config) do
    host = Keyword.fetch!(config, :host)
    port = Keyword.fetch!(config, :port)

    host
    |> WS.connect(port, config)
    |> case do
      {:ok, conn_pid, tunnel_ref} ->
        Process.monitor(conn_pid)
        %State{state | status: :connected, conn_pid: conn_pid, tunnel_ref: tunnel_ref}

      {:error, error} ->
        Logger.error("Can't connect to graph: #{inspect(error)}")
        state
    end
  end

  defp _max_frame_bytes(config),
    do: Keyword.get(config, :ws_max_frame_bytes, @default_max_frame_bytes)

  # `_connect/2` leaves `conn_pid` nil when it could not reach the graph at all.
  defp _ws_upgrade(%State{conn_pid: nil}, _path, _subprotocol, _token, _max_frame_bytes),
    do: {:stop, :not_connected}

  defp _ws_upgrade(%State{conn_pid: conn_pid} = state, path, subprotocol, token, max_frame_bytes) do
    Logger.info("Upgrading connection...")

    conn_pid
    |> WS.ws_upgrade(path, subprotocol, token, state.tunnel_ref, max_frame_bytes)
    |> case do
      {:ok, stream_ref} ->
        {:ok, _upgraded(state, stream_ref)}

      # Refusing to start is what lets `ConnectionManager` back off.
      {:error, reason} ->
        Logger.error("WebSocket upgrade failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  defp _upgraded(%State{} = state, stream_ref) do
    Logger.info("WebSocket upgrade succeeded.")

    if Application.get_env(:graph_conn, :proxy) do
      # Something's wrong with sending pings when connected via proxy so we need to do that on our own.
      Process.send_after(self(), :send_ping, Keyword.get(state.ws_ping, :interval_in_ms))
    end

    Process.send_after(self(), :check_last_pong, Keyword.get(state.ws_ping, :interval_in_ms))
    %State{state | stream_ref: stream_ref}
  end
end
