defmodule GraphConn.WsConnection do
  @moduledoc false

  use GenServer
  alias GraphConn.{WS, Request, Instrumenter}
  require Logger

  defmodule State do
    @moduledoc false

    @type t() :: %__MODULE__{
            base_name: atom(),
            api: atom(),
            internal_state: map(),
            status: GraphConn.status(),
            last_pong: DateTime.t(),
            last_upgrade: DateTime.t() | nil,
            ws_ping: [
              interval_in_ms: pos_integer(),
              reconnect_after_missing_pings: pos_integer()
            ],
            conn_pid: nil | pid(),
            stream_ref: nil | reference()
          }

    @enforce_keys ~w(base_name api internal_state status last_pong last_upgrade ws_ping)a
    defstruct @enforce_keys ++ ~w(conn_pid stream_ref)a
  end

  defp _name(base_name, api) do
    base_name
    |> Module.concat(api)
    |> Module.concat(WsConnection)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, opts},
      type: :worker,
      restart: :temporary
    }
  end

  @spec start_link(atom(), atom(), Keyword.t(), map(), map(), String.t()) :: GenServer.on_start()
  def start_link(base_name, api, config, internal_state, version, token) do
    GenServer.start_link(__MODULE__, {base_name, api, config, internal_state, version, token},
      name: _name(base_name, api)
    )
  end

  def execute(server, %Request{} = request),
    do: GenServer.cast(server, {:execute, request})

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
        last_upgrade: nil
      }
      |> _connect(config)
      |> _ws_upgrade(path, version.subprotocol, token)

    {:ok, state}
  end

  defp _url_params(config) do
    config
    |> Keyword.get(:url_params, %{})
    |> URI.encode_query()
  end

  defp _default_ping_config() do
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

  @impl GenServer
  def handle_info(
        {:gun_ws, conn_pid, _stream_ref, {:text, text}},
        %State{conn_pid: conn_pid} = state
      ) do
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

      _handle_message(msg, state)
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

  def handle_info({:gun_ws, _, _, :close}, %State{} = state) do
    {:stop, "server sent close request", state}
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

  defp _handle_message(%{"type" => "hello"} = msg, _state) do
    Logger.info("[WsConnection] Received hello message: #{inspect(msg)}")
  end

  defp _handle_message(%{} = msg, state),
    do: apply(state.base_name, :handle_message, [state.api, msg, state.internal_state])

  ## Helper functions

  @spec _connect(State.t(), Keyword.t()) :: State.t()
  defp _connect(%State{} = state, config) do
    host = Keyword.fetch!(config, :host)
    port = Keyword.fetch!(config, :port)

    WS.connect(host, port, config)
    |> case do
      {:ok, conn_pid} ->
        Process.monitor(conn_pid)
        %State{state | status: :connected, conn_pid: conn_pid}

      {:error, error} ->
        Logger.error("Can't connect to graph: #{inspect(error)}")
        state
    end
  end

  defp _ws_upgrade(%State{conn_pid: conn_pid} = state, path, subprotocol, token) do
    Logger.info("Upgrading connection...")
    {:ok, stream_ref} = WS.ws_upgrade(conn_pid, path, subprotocol, token)
    last_upgrade = DateTime.utc_now()
    Logger.info("WebSocket upgrade succeeded.")

    if Application.get_env(:graph_conn, :proxy) do
      # Something's wrong with sending pings when connected via proxy so we need to do that on our own.
      Process.send_after(self(), :send_ping, Keyword.get(state.ws_ping, :interval_in_ms))
    end

    Process.send_after(self(), :check_last_pong, Keyword.get(state.ws_ping, :interval_in_ms))
    %State{state | stream_ref: stream_ref, last_upgrade: last_upgrade}
  end
end
