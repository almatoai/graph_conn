defmodule GraphConn.ConnectionManager do
  @moduledoc """
  Per-client connection supervisor and authentication state holder.

  Owns the auth token (acquired and refreshed via `GraphConn.GraphRestCalls`),
  the cached set of API versions advertised by the Graph server, and the map
  of open WebSocket connections. Public functions `execute/3`,
  `open_ws_connection/2`, and `status/1` are invoked through the
  `use GraphConn` entrypoint module.
  """

  defmodule State do
    @moduledoc false

    @type t() :: %__MODULE__{
            base_name: atom(),
            ws_connections: map(),
            status: GraphConn.status(),
            desired_status: GraphConn.status()
          }

    @enforce_keys ~w(base_name ws_connections status desired_status)a
    defstruct @enforce_keys
  end

  use GenServer

  alias GraphConn.{
    ClientState,
    GraphRestCalls,
    Request,
    Response,
    ResponseError,
    WsConnection,
    WsConnections
  }

  require Logger

  @typep version() :: %{path: String.t(), protocol: String.t(), subprotocol: String.t()}

  # How long a caller waits for a client to become usable before giving up, and how often it
  # looks while waiting. See `_await_versions/1`.
  @default_startup_wait 500
  @startup_poll_interval 10

  # we need public access to the table so we can change token from test process.
  @doc false
  @spec _ets_opts(opts :: list()) :: list()
  if Mix.env() == :test do
    defp _ets_opts(opts), do: [:public | opts]
  else
    defp _ets_opts(opts), do: opts
  end

  defp _name(base_name),
    do: Module.concat(base_name, ConnectionManager)

  @doc false
  @spec child_spec(opts :: [atom() | Keyword.t()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, opts},
      type: :worker
    }
  end

  @doc false
  @spec start_link(base_name :: atom(), config :: Keyword.t()) :: GenServer.on_start()
  def start_link(base_name, config) do
    GenServer.start_link(__MODULE__, {base_name, config}, name: _name(base_name))
  end

  @doc "Returns current connection status for `base_name`."
  @spec status(base_name :: atom()) :: GraphConn.status()
  def status(base_name) do
    base_name
    |> _name()
    |> GenServer.call(:status)
  end

  @doc """
  Executes `request` against `target_api`. REST APIs go via HTTP; WS APIs are
  dispatched through the associated WebSocket connection.

  Returns `{:error, :not_started}` if no connection is ready for `base_name` (see
  `_await_versions/1`).
  """
  @spec execute(
          base_name :: atom(),
          target_api :: atom(),
          Request.t(),
          opts :: Keyword.t()
        ) ::
          :ok
          | {:ok, Response.t()}
          | {:error, ResponseError.t()}
          | {:error, {:unknown_api, [any()]}}
          | {:error, :not_started}
  def execute(base_name, target_api, %Request{} = request, opts \\ []) do
    case _get_version(base_name, target_api) do
      {:ok, %{protocol: ""}} -> _execute_rest(base_name, target_api, request, opts)
      {:ok, _} -> _execute_ws(base_name, target_api, request)
      other -> other
    end
  end

  @doc """
  Asynchronously opens a WebSocket connection to `target_api` if not already
  open. Returns `:ok` immediately; status changes are reported via the
  `on_status_change/3` callback.
  """
  @spec open_ws_connection(base_name :: atom(), target_api :: atom()) ::
          :ok | {:error, {:unknown_api, [atom()]}}
  def open_ws_connection(base_name, target_api) do
    base_name
    |> _name()
    |> GenServer.cast({:open_ws_connection, target_api})
  end

  defp _execute_rest(base_name, target_api, request, opts, attempt \\ 1) do
    case GraphRestCalls.execute(base_name, target_api, request, opts) do
      {:ok, %Response{code: 401}} = result ->
        # Don't refresh token if request is made on behalf of another entity or if we've already
        # tried refreshing once, to avoid infinite loop in case of other auth issues.
        if Request.on_behalf_auth?(request) or attempt > 1 do
          result
        else
          Logger.warning("Token has unexpectedly expired. Refreshing token and retrying call...")

          :ok =
            base_name
            |> _name()
            |> GenServer.call(:refresh_token)

          _execute_rest(base_name, target_api, request, opts, attempt + 1)
        end

      other ->
        other
    end
  end

  @impl GenServer
  def init({base_name, config}) do
    _init_ets(base_name, config)

    desired_status =
      config
      |> Keyword.get(:auto_connect, true)
      |> case do
        false -> {:disconnected, :started}
        :just_versions -> :got_api_versions
        true -> :ready
      end

    send(self(), :connect)
    status = {:disconnected, :started}

    state = %State{
      base_name: base_name,
      ws_connections: %{},
      status: status,
      desired_status: desired_status
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, %State{status: status} = state),
    do: {:reply, status, state}

  def handle_call({:open_ws_connection, target_api}, _from, %State{} = state) do
    case _get_version(state.base_name, target_api) do
      {:ok, version} ->
        [{:config, config}] = :ets.lookup(state.base_name, :config)
        [{:token, token}] = :ets.lookup(state.base_name, :token)
        config = Keyword.put(config, :protocols, [:http])
        client_state = ClientState.get_state(state.base_name)

        conn_pid =
          state.base_name
          |> WsConnections.start_connection(target_api, config, client_state, version, token)
          |> case do
            {:ok, conn_pid} ->
              _conn_ref = Process.monitor(conn_pid)
              conn_pid

            {:error, {:already_started, conn_pid}} ->
              conn_pid
          end

        state = %{state | ws_connections: Map.put(state.ws_connections, conn_pid, target_api)}

        _update_ets(state.base_name, {target_api, :conn_pid}, conn_pid)
        _status_changed(target_api, :ready, state)
        {:reply, {:ok, conn_pid}, state}

      no_version_found ->
        {:reply, no_version_found, state}
    end
  end

  def handle_call(:refresh_token, _, %State{} = state) do
    {_, %State{} = new_state} = _get_token(state, {:refresh_token, 1_000})
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_cast({:open_ws_connection, target_api}, %State{} = state) do
    {:reply, _, state} = handle_call({:open_ws_connection, target_api}, self(), state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:connect, %State{status: status, desired_status: status} = state),
    do: {:noreply, state}

  def handle_info(:connect, %State{} = state),
    do: handle_info({:connect, 1_000}, state)

  def handle_info({:connect, retry_in}, %State{status: status} = state) do
    case status do
      {:disconnected, _} -> _get_versions(state)
      :got_api_versions -> _get_token(state, {:connect, retry_in})
      :ready -> {:noreply, state}
    end
  end

  def handle_info(:refresh_token, %State{} = state),
    do: handle_info({:refresh_token, 1_000}, state)

  def handle_info({:refresh_token, refresh_in}, %State{status: :ready} = state),
    do: _get_token(state, {:refresh_token, refresh_in})

  def handle_info({:refresh_token, _}, %State{} = state),
    do: {:noreply, state}

  def handle_info({:DOWN, _, :process, conn_pid, reason}, %State{} = state) do
    api = Map.get(state.ws_connections, conn_pid)
    _status_changed(api, reason, state)
    _update_ets(state.base_name, {api, :conn_pid}, nil)
    state = %{state | ws_connections: Map.delete(state.ws_connections, conn_pid)}
    {:reply, _, state} = handle_call({:open_ws_connection, api}, self(), state)
    {:noreply, state}
  end

  ## Helper functions

  @spec _get_versions(State.t()) :: {:noreply, State.t()}
  defp _get_versions(%State{} = state) do
    [{:config, config}] = :ets.lookup(state.base_name, :config)

    state =
      case GraphRestCalls.get_versions(state.base_name, config) do
        {:ok, versions} ->
          _update_ets(state.base_name, :versions, versions)
          _status_changed(:got_api_versions, state)
          send(self(), :connect)
          %State{state | status: :got_api_versions}

        {:error, _error} ->
          Process.send_after(self(), :connect, 1_000)
          state
      end

    {:noreply, state}
  end

  @spec _get_token(
          State.t(),
          flow :: {:connect | :refresh_token, retry_in_ms :: non_neg_integer()}
        ) ::
          {:noreply, State.t()}
  defp _get_token(%State{} = state, {retry_message, retry_in}) do
    [{:config, config}] = :ets.lookup(state.base_name, :config)
    [{:versions, versions}] = :ets.lookup(state.base_name, :versions)

    case GraphRestCalls.authenticate(state.base_name, config, versions) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
        # refresh token when it is said that it will expire
        refresh_in = expires_at - now

        Process.send_after(self(), :refresh_token, refresh_in)
        _update_ets(state.base_name, :token, token)
        _status_changed(:ready, state)
        {:noreply, %State{state | status: :ready}}

      {:error, :wrong_credentials} ->
        {:stop, :wrong_credentials, state}

      {:error, _error} ->
        Process.send_after(self(), {retry_message, retry_in * 2}, retry_in)
        {:noreply, state}
    end
  end

  defp _status_changed(status, %State{status: status}),
    do: :noop

  defp _status_changed(new_status, %State{} = state) do
    client_state = ClientState.get_state(state.base_name)
    apply(state.base_name, :on_status_change, [new_status, client_state])
  end

  defp _status_changed(api, new_status, %State{} = state) do
    client_state = ClientState.get_state(state.base_name)
    apply(state.base_name, :on_status_change, [api, new_status, client_state])
  end

  @spec _execute_ws(base_name :: atom(), target_api :: atom(), Request.t()) ::
          :ok | {:error, {:unknown_api, [atom()]}}
  defp _execute_ws(base_name, target_api, request) do
    with {:ok, conn_pid} <- _get_ws_connection(base_name, target_api) do
      conn_pid
      |> WsConnection.execute(request)
    end
  end

  @spec _get_ws_connection(base_name :: atom(), target_api :: atom()) ::
          {:ok, pid()} | {:error, {:unknown_api, [atom()]}}
  defp _get_ws_connection(base_name, target_api) do
    case :ets.lookup(base_name, {target_api, :conn_pid}) do
      [{{^target_api, :conn_pid}, nil}] ->
        Logger.warning("WS connection is down! Retrying message sending...")
        Process.sleep(5)
        _get_ws_connection(base_name, target_api)

      [{{^target_api, :conn_pid}, conn_pid}] ->
        {:ok, conn_pid}

      [] ->
        base_name
        |> _name()
        |> GenServer.call({:open_ws_connection, target_api})
    end
  end

  @spec _get_version(base_name :: atom(), target_api :: atom()) ::
          {:ok, version()} | {:error, {:unknown_api, [atom()]}} | {:error, :not_started}
  defp _get_version(base_name, target_api) do
    case _await_versions(base_name) do
      :not_started ->
        Logger.warning(
          "No connection is ready for #{inspect(base_name)}, refusing #{target_api} request. " <>
            "Is it started in a supervision tree, and can it reach the graph?"
        )

        {:error, :not_started}

      versions ->
        case Map.get(versions, target_api) do
          nil -> {:error, {:unknown_api, Map.keys(versions)}}
          version -> {:ok, version}
        end
    end
  end

  @spec _init_ets(base_name :: atom(), config :: Keyword.t()) :: true
  defp _init_ets(base_name, config) do
    opts = [:named_table, read_concurrency: true]

    ^base_name = :ets.new(base_name, _ets_opts(opts))

    config = parse_urls(config)
    _reset_ets(base_name, config)
  end

  @spec _reset_ets(base_name :: atom(), config :: Keyword.t()) :: true
  defp _reset_ets(base_name, config) do
    _update_ets(base_name, :token, nil)
    _update_ets(base_name, :versions, %{})
    _update_ets(base_name, :config, config)
  end

  @spec _update_ets(base_name :: atom(), key :: term(), value :: term()) :: true
  defp _update_ets(base_name, key, value) do
    true = :ets.insert(base_name, {key, value})
  end

  # Waits, bounded, for `base_name` to become usable and returns the API versions it picked up
  # from the graph, or `:not_started` if it doesn't get there in time.
  #
  # A caller can arrive too early twice over: the table is created in `init/1` and
  # `GraphConn.Supervisor` starts that child last, and the versions land only once the graph has
  # answered `_get_versions/1` -- until then the table holds an empty map. Two stages of one
  # start-up, so they share one deadline: `:startup_wait_ms` (`:graph_conn` app env, 500ms by
  # default; 0 to fail immediately). The cap matters because the client may not be coming at all
  # -- disabled by configuration, or never added to a supervision tree -- and an uncapped wait
  # leaves the caller blocked.
  @spec _await_versions(base_name :: atom()) :: %{atom() => version()} | :not_started
  defp _await_versions(base_name),
    do: _await_versions(base_name, System.monotonic_time(:millisecond) + _startup_wait())

  @spec _await_versions(base_name :: atom(), deadline :: integer()) ::
          %{atom() => version()} | :not_started
  defp _await_versions(base_name, deadline) do
    case _read_versions(base_name) do
      {:ok, versions} when map_size(versions) > 0 ->
        versions

      _no_table_or_no_versions_yet ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@startup_poll_interval)
          _await_versions(base_name, deadline)
        else
          :not_started
        end
    end
  end

  # Resolves the name once and reads through the tid, so the read can't hit a *different* table
  # than the one just found. A table that isn't readable is reported as simply not being there
  # yet, which is what both races here amount to: this process owns the table, so it takes it down
  # with it whenever it is restarted and a caller landing in that gap should wait for the
  # replacement, and `_init_ets/2` creates the table a moment before it inserts `:versions` into
  # it. Neither is worth an `ArgumentError` in the caller.
  @spec _read_versions(base_name :: atom()) :: {:ok, %{atom() => version()}} | :error
  defp _read_versions(base_name) do
    case :ets.whereis(base_name) do
      :undefined -> :error
      tid -> {:ok, :ets.lookup_element(tid, :versions, 2)}
    end
  rescue
    ArgumentError -> :error
  end

  @spec _startup_wait() :: non_neg_integer()
  defp _startup_wait,
    do: Application.get_env(:graph_conn, :startup_wait_ms, @default_startup_wait)

  @spec parse_urls(config :: Keyword.t()) :: Keyword.t()
  def parse_urls(config) do
    %URI{
      host: host,
      port: port,
      scheme: scheme
    } =
      config
      |> Keyword.fetch!(:url)
      |> URI.parse()

    auth_config = Keyword.get(config, :auth, [])

    %URI{
      host: auth_host,
      port: auth_port,
      scheme: auth_scheme
    } =
      auth_config
      |> Keyword.get(:url, config[:url])
      |> URI.parse()

    config =
      config
      |> Keyword.put(:host, host)
      |> Keyword.put(:port, port)
      |> Keyword.put(:transport, _transport_for_scheme(scheme))
      |> Keyword.put(:insecure, _insecure_for_scheme(scheme, config[:insecure]))

    auth_config =
      auth_config
      |> Keyword.put(:host, auth_host)
      |> Keyword.put(:port, auth_port)
      |> Keyword.put(:transport, _transport_for_scheme(auth_scheme))
      |> Keyword.put(
        :insecure,
        _insecure_for_scheme(scheme, Keyword.get(auth_config, :insecure, config[:insecure]))
      )

    Keyword.put(config, :auth, auth_config)
  end

  defp _transport_for_scheme("https"), do: :tls
  defp _transport_for_scheme("http"), do: :tcp

  defp _insecure_for_scheme("http", _), do: true
  defp _insecure_for_scheme("https", insecure), do: insecure
end
