defmodule GraphConn.ConnectionManager do
  defmodule State do
    @moduledoc false

    @type t() :: %__MODULE__{
            base_name: atom(),
            ws_connections: map(),
            status: GraphConn.status(),
            last_token: DateTime.t() | nil
          }

    @enforce_keys ~w(base_name ws_connections status last_token)a
    defstruct @enforce_keys
  end

  use GenServer

  alias GraphConn.{
    ClientState,
    WsConnections,
    WsConnection,
    GraphRestCalls,
    Request,
    Response,
    ResponseError
  }

  require Logger

  @typep version() :: %{path: String.t(), protocol: String.t(), subprotocol: String.t()}

  # we need public access to the table so we can change token from test process.
  if Mix.env() == :test do
    def _ets_opts(opts), do: [:public | opts]
  else
    def _ets_opts(opts), do: opts
  end

  defp _name(base_name),
    do: Module.concat(base_name, ConnectionManager)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, opts},
      type: :worker
    }
  end

  def start_link(base_name, config) do
    GenServer.start_link(__MODULE__, {base_name, config}, name: _name(base_name))
  end

  @spec status(atom()) :: GraphConn.status()
  def status(base_name) do
    base_name
    |> _name()
    |> GenServer.call(:status)
  end

  @spec execute(atom(), atom(), Request.t(), Keyword.t()) ::
          :ok
          | {:ok, Response.t()}
          | {:error, ResponseError.t()}
          | {:error, {:unknown_api, [any()]}}
  def execute(base_name, target_api, %Request{} = request, opts \\ []) do
    case _get_version(base_name, target_api) do
      {:ok, %{protocol: ""}} -> _execute_rest(base_name, target_api, request, opts)
      {:ok, _} -> _execute_ws(base_name, target_api, request)
      other -> other
    end
  end

  @spec open_ws_connection(atom(), atom()) :: :ok | {:error, {:unknown_api, [atom()]}}
  def open_ws_connection(base_name, target_api) do
    base_name
    |> _name()
    |> GenServer.cast({:open_ws_connection, target_api})
  end

  defp _execute_rest(base_name, target_api, request, opts) do
    case GraphRestCalls.execute(base_name, target_api, request, opts) do
      {:ok, %Response{code: 401}} ->
        Logger.warning("Token has unexpectedly expired. Refreshing token and retrying call...")

        :ok =
          base_name
          |> _name()
          |> GenServer.call(:refresh_token)

        _execute_rest(base_name, target_api, request, opts)

      other ->
        other
    end
  end

  @impl GenServer
  def init({base_name, config}) do
    _init_ets(base_name, config)
    send(self(), :connect)
    status = {:disconnected, :started}

    state = %State{
      base_name: base_name,
      ws_connections: %{},
      status: status,
      last_token: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, %State{status: status} = state),
    do: {:reply, status, state}

  def handle_call({:open_ws_connection, target_api}, _from, %State{} = state) do
    with {:ok, version} <- _get_version(state.base_name, target_api) do
      [{:config, config}] = :ets.lookup(state.base_name, :config)
      [{:token, token}] = :ets.lookup(state.base_name, :token)
      config = Keyword.put(config, :protocols, [:http])
      client_state = ClientState.get_state(state.base_name)

      conn_pid =
        WsConnections.start_connection(
          state.base_name,
          target_api,
          config,
          client_state,
          version,
          token
        )
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
    else
      no_version_found -> {:reply, no_version_found, state}
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
          send(self(), :connect)
          %State{state | status: :got_api_versions}

        {:error, _error} ->
          Process.send_after(self(), :connect, 1_000)
          state
      end

    {:noreply, state}
  end

  @spec _get_token(State.t(), {:connect | :refresh_token, retry_in_ms :: non_neg_integer()}) ::
          {:noreply, State.t()}
  defp _get_token(%State{} = state, {retry_message, retry_in}) do
    [{:config, config}] = :ets.lookup(state.base_name, :config)
    [{:versions, versions}] = :ets.lookup(state.base_name, :versions)

    case GraphRestCalls.authenticate(state.base_name, config, versions) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        utc_now = DateTime.utc_now()
        now = utc_now |> DateTime.to_unix(:millisecond)
        # refresh token when it is said that it will expire
        refresh_in = expires_at - now

        Process.send_after(self(), :refresh_token, refresh_in)
        _update_ets(state.base_name, :token, token)
        _status_changed(:ready, state)
        {:noreply, %State{state | status: :ready, last_token: utc_now}}

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

  @spec _execute_ws(atom(), atom(), Request.t()) ::
          :ok | {:error, {:unknown_api, [atom()]}}
  defp _execute_ws(base_name, target_api, request) do
    with {:ok, conn_pid} <- _get_ws_connection(base_name, target_api) do
      conn_pid
      |> WsConnection.execute(request)
    end
  end

  @spec _get_ws_connection(atom(), atom()) :: {:ok, pid()} | {:error, {:unknown_api, [atom()]}}
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

  @spec _get_version(atom(), atom(), pos_integer()) ::
          {:ok, version()} | {:error, {:unknown_api, [atom()]}}
  defp _get_version(base_name, target_api, attempt \\ 1)

  defp _get_version(_, _, 6),
    do: {:error, {:unknown_api, []}}

  defp _get_version(base_name, target_api, attempt) do
    versions = _ets_versions(base_name)

    case Map.get(versions, target_api) do
      nil ->
        if versions == %{} do
          Process.sleep(20)
          _get_version(base_name, target_api, attempt + 1)
        else
          {:error, {:unknown_api, Map.keys(versions)}}
        end

      version ->
        {:ok, version}
    end
  end

  @spec _init_ets(atom(), Keyword.t()) :: true
  defp _init_ets(base_name, config) do
    opts = [:named_table, read_concurrency: true]

    ^base_name = :ets.new(base_name, _ets_opts(opts))

    config = parse_urls(config)
    _reset_ets(base_name, config)
  end

  @spec _reset_ets(atom(), Keyword.t()) :: true
  defp _reset_ets(base_name, config) do
    _update_ets(base_name, :token, nil)
    _update_ets(base_name, :versions, %{})
    _update_ets(base_name, :config, config)
  end

  @spec _update_ets(atom(), term(), term()) :: true
  defp _update_ets(base_name, key, value) do
    true = :ets.insert(base_name, {key, value})
  end

  defp _ets_versions(base_name) do
    if :ets.whereis(base_name) == :undefined do
      Process.sleep(10)
      _ets_versions(base_name)
    else
      [{:versions, versions}] = :ets.lookup(base_name, :versions)
      versions
    end
  end

  @spec parse_urls(Keyword.t()) :: Keyword.t()
  def parse_urls(config) do
    %URI{
      host: host,
      port: port,
      scheme: scheme
    } =
      config
      |> Keyword.fetch!(:url)
      |> URI.parse()

    auth_config = Keyword.fetch!(config, :auth)

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
