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
            desired_status: GraphConn.status(),
            refused_apis: MapSet.t(atom())
          }

    @enforce_keys ~w(base_name ws_connections status desired_status)a
    defstruct @enforce_keys ++ [refused_apis: MapSet.new()]
  end

  use GenServer

  alias GraphConn.{
    Backoff,
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
  @default_status_timeout 5_000
  @default_auth_timeout 60_000
  @refresh_call_margin 1_000
  @startup_poll_interval 10

  # Retry backoff defaults. See `__next_retry__/2` and `_clamp_floor/1`.
  @default_retry_initial 1_000
  @default_retry_max 10_000
  @default_retry_jitter 1_000
  @default_retry_floor_max 300_000
  @default_token_refresh_ratio 0.95

  # Derived from the backoff ceiling, so raising it cannot silently narrow the margin.
  @refresh_margin_denials 3

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

  @doc """
  Returns current connection status for `base_name`.

  `timeout` bounds the wait on the manager, which shares a mailbox with token refreshes and so
  can be busy for as long as one takes.
  """
  @spec status(base_name :: atom(), timeout :: timeout()) :: GraphConn.status()
  def status(base_name, timeout \\ @default_status_timeout) do
    base_name
    |> _name()
    |> GenServer.call(:status, timeout)
  end

  # The refresh runs the authentication call inside the manager, so a caller that gives up first
  # turns a slow Graph into an exit in its own process instead of an error it can handle.
  @doc false
  @spec __refresh_call_timeout__(config :: Keyword.t()) :: timeout()
  def __refresh_call_timeout__(config) do
    config
    |> Keyword.get(:auth, [])
    |> Keyword.get(:timeout, @default_auth_timeout)
    |> Kernel.+(@refresh_call_margin)
  end

  @doc """
  Executes `request` against `target_api`. REST APIs go via HTTP; WS APIs are
  dispatched through the associated WebSocket connection.

  Returns `{:error, :not_started}` if no connection is ready for `base_name` (see
  `_await_versions/1`), or `{:error, {:rate_limited, retry_after_ms}}` if a WS API's connection is
  waiting out a rate limit before it reopens -- `retry_after_ms` is how long to wait, in
  milliseconds, and is `0` once the window has passed. A WS connection that does not come back
  inside `:startup_wait_ms` is `{:error, :ws_connection_down}`, kept distinct from
  `:not_started` so a flapping socket cannot be mistaken for a client that never came up.
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
          | {:error, :ws_connection_down}
          | {:error, {:rate_limited, retry_after_ms :: non_neg_integer()}}
          | {:error, reason :: term()}
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

          _refresh_and_retry(result, base_name, target_api, request, opts, attempt)
        end

      other ->
        other
    end
  end

  # Credentials the Graph rejects outright leave the caller with the 401 it already has: the
  # manager stops on its way out, so there is no token coming and no point in a second attempt.
  defp _refresh_and_retry(result, base_name, target_api, request, opts, attempt) do
    [{:config, config}] = :ets.lookup(base_name, :config)
    refresh_timeout = __refresh_call_timeout__(config)

    base_name
    |> _name()
    |> GenServer.call(:refresh_token, refresh_timeout)
    |> case do
      :ok -> _execute_rest(base_name, target_api, request, opts, attempt + 1)
      {:error, _rejected} -> result
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

  # Guarded here rather than in `_open_ws/3`, deliberately: this is the door consumers use -- and
  # `handle_cast/2` below routes through it -- while the scheduled reopen calls `_open_ws/3`
  # directly and must not be blocked by the very stamp it is working off.
  def handle_call({:open_ws_connection, target_api}, _from, %State{} = state) do
    state.base_name
    |> _hold_until(target_api)
    |> case do
      nil -> _open_ws(state, target_api, _initial(), :reopen_ws)
      reopen_at -> {:reply, {:error, {:rate_limited, _retry_after_ms(reopen_at)}}, state}
    end
  end

  def handle_call(:refresh_token, _from, %State{} = state) do
    state
    |> _get_token({:refresh_token, _initial()})
    |> case do
      {:noreply, %State{} = new_state} -> {:reply, :ok, new_state}
      {:stop, reason, %State{} = new_state} -> {:stop, reason, {:error, reason}, new_state}
    end
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
    do: handle_info({:connect, _initial()}, state)

  def handle_info({:connect, retry_in}, %State{status: status} = state) do
    case status do
      {:disconnected, _} -> _get_versions(state, retry_in)
      :got_api_versions -> _get_token(state, {:connect, retry_in})
      :ready -> {:noreply, state}
    end
  end

  def handle_info(:refresh_token, %State{} = state),
    do: handle_info({:refresh_token, _initial()}, state)

  def handle_info({:refresh_token, refresh_in}, %State{status: :ready} = state),
    do: _get_token(state, {:refresh_token, refresh_in})

  def handle_info({:refresh_token, _}, %State{} = state),
    do: {:noreply, state}

  # `desired_status` is set once in `init/1` and never changes, so the reachable case is a client
  # configured with `auto_connect: false` or `:just_versions` -- not a connection closed later.
  def handle_info({:reopen_ws, api, _retry_in, _hold}, %State{desired_status: desired} = state)
      when desired != :ready do
    _update_ets(state.base_name, {api, :reopen_at}, nil)
    {:noreply, state}
  end

  def handle_info({:reopen_ws, api, retry_in, _hold}, %State{status: :ready} = state) do
    {:reply, _reply, %State{} = state} = _open_ws(state, api, retry_in, :reopen_ws)
    {:noreply, state}
  end

  # Wanted, but the token is not in ETS yet: `status` never regresses from `:ready`, so this is
  # the start-up window -- versions have landed, the token has not, and a caller forced an open
  # that the graph refused. Re-schedule rather than drop, carrying the same stamp policy, or a
  # refusal that was never a rate limit would start reporting as one.
  def handle_info({:reopen_ws, api, retry_in, hold}, %State{} = state) do
    _reopen_later(state, api, retry_in, hold, :reopen_ws)
    {:noreply, state}
  end

  # The client opened this socket and only a drop closed it, so neither `desired_status` nor the
  # manager's own status gets a say in whether it comes back.
  def handle_info({:reopen_dropped_ws, api, retry_in, _hold}, %State{} = state) do
    {:reply, _reply, %State{} = state} = _open_ws(state, api, retry_in, :reopen_dropped_ws)
    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor_ref, :process, conn_pid, reason}, %State{} = state) do
    api = Map.get(state.ws_connections, conn_pid)
    _status_changed(api, reason, state)
    _update_ets(state.base_name, {api, :conn_pid}, nil)
    state = %{state | ws_connections: Map.delete(state.ws_connections, conn_pid)}

    {:noreply, _reopen_unless_rejected(state, api, reason)}
  end

  @doc false
  @spec __refresh_in__(expires_at :: integer(), now :: integer()) ::
          refresh_in_ms :: non_neg_integer()
  def __refresh_in__(expires_at, now) do
    lifetime = expires_at - now
    margin = _refresh_margin(lifetime)

    _refresh_in(lifetime, margin)
  end

  @doc false
  @spec __next_retry__(retry_in :: non_neg_integer(), advertised_ms :: non_neg_integer()) ::
          {delay :: pos_integer(), next_current :: pos_integer()}
  def __next_retry__(retry_in, advertised_ms) do
    configured_cap = Application.get_env(:graph_conn, :retry_max_ms, @default_retry_max)
    seed = _initial()

    # A cap under the seed would pin the curve at a 1ms retry, so the seed is its lowest sane value.
    cap = max(configured_cap, seed)
    spread = Application.get_env(:graph_conn, :retry_jitter_ms, @default_retry_jitter)
    floor_ms = _clamp_floor(advertised_ms)

    Backoff.next_delay(retry_in, floor_ms, cap, spread)
  end

  ## Helper functions

  @spec _open_ws(
          State.t(),
          target_api :: atom(),
          retry_in_ms :: non_neg_integer(),
          reopen_tag :: :reopen_ws | :reopen_dropped_ws
        ) :: {:reply, term(), State.t()}
  defp _open_ws(%State{} = state, target_api, retry_in, reopen_tag) do
    case _get_version(state.base_name, target_api) do
      {:ok, version} ->
        _start_ws_connection(state, target_api, version, retry_in, reopen_tag)

      no_version_found ->
        # Nothing is scheduled to reopen this, so a stamp left behind would park callers on
        # "retry now" forever. Clearing it puts them back on the ordinary spin.
        _update_ets(state.base_name, {target_api, :reopen_at}, nil)
        {:reply, no_version_found, state}
    end
  end

  defp _start_ws_connection(%State{} = state, target_api, version, retry_in, reopen_tag) do
    [{:config, config}] = :ets.lookup(state.base_name, :config)
    [{:token, token}] = :ets.lookup(state.base_name, :token)
    config = Keyword.put(config, :protocols, [:http])
    client_state = ClientState.get_state(state.base_name)

    state.base_name
    |> WsConnections.start_connection(target_api, config, client_state, version, token)
    |> case do
      {:ok, conn_pid} ->
        _conn_ref = Process.monitor(conn_pid)
        _ws_connection_opened(state, target_api, conn_pid)

      {:error, {:already_started, conn_pid}} ->
        _ws_connection_opened(state, target_api, conn_pid)

      {:error, {:rate_limited, advertised_ms}} ->
        _rate_limited_reopen(state, target_api, retry_in, advertised_ms, reopen_tag)

      # The catch-all is the load-bearing clause: without it ANY upgrade failure -- not just a
      # 429 -- is a CaseClauseError here, and that takes down the whole :one_for_all subtree.
      {:error, reason} ->
        _failed_reopen(state, target_api, retry_in, reason, reopen_tag)
    end
  end

  defp _ws_connection_opened(%State{} = state, target_api, conn_pid) do
    state = %{state | ws_connections: Map.put(state.ws_connections, conn_pid, target_api)}

    _update_ets(state.base_name, {target_api, :conn_pid}, conn_pid)
    _update_ets(state.base_name, {target_api, :reopen_at}, nil)
    _status_changed(target_api, :ready, state)
    {:reply, {:ok, conn_pid}, state}
  end

  # A 429, and only a 429. The stamp is what lets `_get_ws_connection/2` answer later callers
  # from ETS; without it each of them mounts its own upgrade and the retry rate follows caller
  # volume rather than the curve.
  defp _rate_limited_reopen(%State{} = state, target_api, retry_in, advertised_ms, reopen_tag) do
    reopen_at = _reopen_later(state, target_api, retry_in, {:hold, advertised_ms}, reopen_tag)

    {:reply, {:error, {:rate_limited, _retry_after_ms(reopen_at)}}, state}
  end

  # Any other upgrade failure. Deliberately does NOT stamp: it is not a rate limit, so later
  # callers wait for the connection to come back rather than being handed a wait to honour --
  # and they give up with `{:error, :ws_connection_down}` once `:startup_wait_ms` is spent. Only
  # the caller that hit the failure is told what it was.
  defp _failed_reopen(%State{} = state, target_api, retry_in, reason, reopen_tag) do
    Logger.error("Opening #{target_api} WS connection failed: #{inspect(reason)}")
    _reopen_later(state, target_api, retry_in, :no_hold, reopen_tag)

    {:reply, {:error, _not_sent_reason(reason)}, state}
  end

  # Small, stable tags rather than whatever the upgrade happened to fail with: a raw
  # `%Response{}` carries headers and a body, and downstream repos inspect this into a string.
  defp _not_sent_reason(%Response{code: status}),
    do: {:upgrade_refused, status}

  defp _not_sent_reason(reason),
    do: reason

  # Nils `conn_pid` so `_get_ws_connection/2` takes its nil branch. Without this an api that has
  # never connected has no row at all, so callers skip the branch entirely and each opens anew.
  # Owns the stamp as well as the timer, so no caller can schedule a reopen and forget to say
  # whether callers should be held. `{:hold, _}` stamps, `:no_hold` clears -- both write, so a
  # stale stamp cannot survive a reschedule. One `delay` feeds both the timer and the stamp, and
  # it is computed before the timer is armed, so a reopen always finds its own hold expired.
  # `handle_call/3` is guarded rather than `_open_ws/3` because that keeps the reopen correct by
  # STRUCTURE -- the public door is the thing being closed -- not by relying on that timing.
  # `reopen_tag` travels with the retry so a failed reopen re-arms the message it arrived on: a
  # dropped socket's recovery must not fall back into the clauses that filter `:reopen_ws`.
  defp _reopen_later(%State{} = state, target_api, retry_in, hold, reopen_tag) do
    advertised_ms = _advertised(hold)
    {delay, next_current} = __next_retry__(retry_in, advertised_ms)
    reopen_at = System.monotonic_time(:millisecond) + delay

    Process.send_after(self(), {reopen_tag, target_api, next_current, hold}, delay)
    _update_ets(state.base_name, {target_api, :conn_pid}, nil)
    _update_ets(state.base_name, {target_api, :reopen_at}, _stamp(hold, reopen_at))
    _log_retry("#{target_api} WS upgrade", delay)

    reopen_at
  end

  # Unpaced, a socket closed for a dead token reopens with that same token as fast as the graph
  # will answer. A reopen already pending owns its own timer, so leave it alone.
  # Reconnecting with a token the server just refused can only be refused again, so the loop stops
  # here. The next request for this api opens it, by which time the token has been refreshed.
  defp _reopen_unless_rejected(
         %State{} = state,
         target_api,
         {:disconnected, {:rejected_by_server, msg}}
       ) do
    Logger.warning(
      "#{target_api} connection was refused (#{msg}); reopening once a new token arrives"
    )

    _update_ets(state.base_name, {target_api, :reopen_at}, nil)

    %State{state | refused_apis: MapSet.put(state.refused_apis, target_api)}
  end

  defp _reopen_unless_rejected(%State{} = state, target_api, _dropped) do
    _reopen_dropped(state, target_api)

    state
  end

  # The token was what the Graph refused, so a fresh one is the first moment reconnecting can
  # work. Nothing else brings these back: a handler never sends a request of its own.
  defp _reopen_refused(%State{} = state) do
    Enum.each(state.refused_apis, &_reopen_dropped(state, &1))

    %State{state | refused_apis: MapSet.new()}
  end

  defp _reopen_dropped(%State{} = state, target_api) do
    state.base_name
    |> _hold_until(target_api)
    |> case do
      nil -> _reopen_later(state, target_api, _initial(), :no_hold, :reopen_dropped_ws)
      _already_pending -> :noop
    end
  end

  defp _refresh_in(lifetime, _margin) when lifetime <= 0,
    do: 0

  # Never later than the margin allows, never earlier than half a life: a lifetime just above the
  # margin would otherwise buy a 1ms refresh and re-authenticate in a tight loop forever.
  defp _refresh_in(lifetime, margin) do
    lifetime
    |> div(2)
    |> max(1)
    |> max(lifetime - margin)
  end

  # Floored as well as proportional: 5% of a minute is under one backoff ceiling.
  defp _refresh_margin(lifetime) do
    ratio = Application.get_env(:graph_conn, :token_refresh_ratio, @default_token_refresh_ratio)
    ceiling = Application.get_env(:graph_conn, :retry_max_ms, @default_retry_max)
    proportional = lifetime - trunc(lifetime * ratio)

    ceiling
    |> Kernel.*(@refresh_margin_denials)
    |> max(proportional)
  end

  # Carried in the reopen message so a rescheduled hold still waits the window the server named,
  # rather than dropping back to the plain curve and earning itself another 429.
  defp _advertised({:hold, advertised_ms}), do: advertised_ms
  defp _advertised(:no_hold), do: 0

  defp _stamp({:hold, _advertised_ms}, reopen_at), do: reopen_at
  defp _stamp(:no_hold, _reopen_at), do: nil

  # The stamp only holds callers back while it is still in the future.
  defp _hold_until(base_name, target_api) do
    base_name
    |> :ets.lookup({target_api, :reopen_at})
    |> case do
      [{{^target_api, :reopen_at}, reopen_at}] when is_integer(reopen_at) ->
        _future_stamp(reopen_at)

      _no_reopen_pending ->
        nil
    end
  end

  defp _future_stamp(reopen_at) do
    reopen_at
    |> _retry_after_ms()
    |> case do
      0 -> nil
      _still_holding -> reopen_at
    end
  end

  @spec _get_versions(State.t(), retry_in_ms :: non_neg_integer()) :: {:noreply, State.t()}
  defp _get_versions(%State{} = state, retry_in) do
    [{:config, config}] = :ets.lookup(state.base_name, :config)

    state =
      case GraphRestCalls.get_versions(state.base_name, config) do
        {:ok, versions} ->
          _update_ets(state.base_name, :versions, versions)
          _status_changed(:got_api_versions, state)
          send(self(), :connect)
          %State{state | status: :got_api_versions}

        {:error, {:rate_limited, advertised_ms}} ->
          _schedule_retry("API version discovery", :connect, retry_in, advertised_ms)
          state

        {:error, _error} ->
          _schedule_retry("API version discovery", :connect, retry_in, 0)
          state
      end

    {:noreply, state}
  end

  @spec _get_token(
          State.t(),
          flow :: {:connect | :refresh_token, retry_in_ms :: non_neg_integer()}
        ) ::
          {:noreply, State.t()} | {:stop, reason :: term(), State.t()}
  defp _get_token(%State{} = state, {retry_message, retry_in}) do
    [{:config, config}] = :ets.lookup(state.base_name, :config)
    [{:versions, versions}] = :ets.lookup(state.base_name, :versions)

    case GraphRestCalls.authenticate(state.base_name, config, versions) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

        _schedule_refresh(expires_at, now, retry_in)
        _update_ets(state.base_name, :token, token)
        _status_changed(:ready, state)

        state = _reopen_refused(%State{state | status: :ready})

        {:noreply, state}

      {:error, :wrong_credentials} ->
        {:stop, :wrong_credentials, state}

      {:error, {:rate_limited, advertised_ms}} ->
        _schedule_retry("authentication", retry_message, retry_in, advertised_ms)
        {:noreply, state}

      {:error, _error} ->
        _schedule_retry("authentication", retry_message, retry_in, 0)
        {:noreply, state}
    end
  end

  # Already expired by OUR clock, which the graph may not share: keep the token and stay `:ready`,
  # because a merely skewed client works fine, but pace the next attempt on the curve -- scheduling
  # it at 0 re-authenticates about a thousand times a second for as long as the condition lasts.
  # Always `:refresh_token`, never the caller's flow: a `{:connect, _}` would be dropped at
  # `:ready` and no refresh would ever be scheduled again.
  defp _schedule_refresh(expires_at, now, retry_in) when expires_at <= now do
    Logger.warning(
      "Token arrived already expired. Check clock skew, or whether `expires-at` is in seconds " <>
        "rather than milliseconds. Refreshing on the retry curve."
    )

    _schedule_retry("token refresh", :refresh_token, retry_in, 0)
  end

  # A live socket is never re-tokened, so the refresh has to beat the expiry.
  defp _schedule_refresh(expires_at, now, _retry_in) do
    refresh_in = __refresh_in__(expires_at, now)

    Process.send_after(self(), :refresh_token, refresh_in)
  end

  # Carries the curve value, never the delay, so an advertised wait can't poison later retries.
  # `site` only labels the log: `:connect` is used by both authentication and version discovery,
  # so the message alone cannot tell an operator which one is backing off.
  defp _schedule_retry(site, retry_message, retry_in, advertised_ms) do
    {delay, next_current} = __next_retry__(retry_in, advertised_ms)

    Process.send_after(self(), {retry_message, next_current}, delay)
    _log_retry(site, delay)
  end

  # The delay actually chosen, after the floor, the cap and any clamping -- which is the number an
  # operator needs and the one no other log line carries.
  defp _log_retry(site, delay),
    do: Logger.warning("Retrying #{site} in #{delay}ms")

  defp _clamp_floor(advertised_ms) do
    :graph_conn
    |> Application.get_env(:retry_floor_max_ms, @default_retry_floor_max)
    |> case do
      ceiling when ceiling <= 0 -> advertised_ms
      ceiling when advertised_ms > ceiling -> _clamped_floor(advertised_ms, ceiling)
      _within_ceiling -> advertised_ms
    end
  end

  defp _clamped_floor(advertised_ms, ceiling) do
    Logger.warning(
      "Advertised retry-after of #{advertised_ms}ms is above :retry_floor_max_ms " <>
        "(#{ceiling}ms), clamping. Another rate limit is likely."
    )

    ceiling
  end

  defp _initial,
    do: Application.get_env(:graph_conn, :retry_initial_ms, @default_retry_initial)

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
          :ok
          | {:error, {:unknown_api, [atom()]}}
          | {:error, {:rate_limited, retry_after_ms :: non_neg_integer()}}
          | {:error, :ws_connection_down}
  defp _execute_ws(base_name, target_api, request) do
    with {:ok, conn_pid} <- _get_ws_connection(base_name, target_api) do
      conn_pid
      |> WsConnection.execute(request)
    end
  end

  @spec _get_ws_connection(base_name :: atom(), target_api :: atom()) ::
          {:ok, pid()}
          | {:error, {:unknown_api, [atom()]}}
          | {:error, {:rate_limited, retry_after_ms :: non_neg_integer()}}
          | {:error, :ws_connection_down}
  defp _get_ws_connection(base_name, target_api),
    do: _get_ws_connection(base_name, target_api, :no_deadline_yet)

  defp _get_ws_connection(base_name, target_api, deadline) do
    case :ets.lookup(base_name, {target_api, :conn_pid}) do
      [{{^target_api, :conn_pid}, nil}] ->
        _await_ws_connection(base_name, target_api, deadline)

      [{{^target_api, :conn_pid}, conn_pid}] ->
        {:ok, conn_pid}

      [] ->
        base_name
        |> _name()
        |> GenServer.call({:open_ws_connection, target_api})
    end
  end

  # Absolute internally, a duration at the edge: the stamp is a deadline this module compares
  # against, but a monotonic reading is node-local and can be negative, so it must never leave.
  # Floored at 0, which reads as "retry now" for a window that has already passed.
  defp _retry_after_ms(reopen_at) do
    remaining = reopen_at - System.monotonic_time(:millisecond)
    max(remaining, 0)
  end

  # Spinning is right for an ordinary blip, where the reopen is immediate. It is wrong once a
  # reopen is deliberately delayed, so a pending stamp turns the spin into an answer.
  defp _await_ws_connection(base_name, target_api, deadline) do
    base_name
    |> :ets.lookup({target_api, :reopen_at})
    |> case do
      [{{^target_api, :reopen_at}, reopen_at}] when is_integer(reopen_at) ->
        {:error, {:rate_limited, _retry_after_ms(reopen_at)}}

      _no_reopen_pending ->
        _spin_for_ws_connection(base_name, target_api, deadline)
    end
  end

  # Bounded by the same `:startup_wait_ms` deadline `execute/4` already waits on, and logged once
  # per caller rather than once per poll: the curve now reaches `:retry_max_ms`, so an unbounded
  # spin is both a caller that never returns and thousands of log lines per caller per outage.
  defp _spin_for_ws_connection(base_name, target_api, :no_deadline_yet) do
    Logger.warning("#{target_api} WS connection is down, waiting for it to come back...")
    deadline = System.monotonic_time(:millisecond) + _startup_wait()

    _spin_for_ws_connection(base_name, target_api, deadline)
  end

  defp _spin_for_ws_connection(base_name, target_api, deadline) do
    now = System.monotonic_time(:millisecond)

    now
    |> case do
      expired when expired >= deadline ->
        Logger.error("#{target_api} WS connection did not come back, giving up")
        {:error, :ws_connection_down}

      _still_waiting ->
        Process.sleep(@startup_poll_interval)
        _get_ws_connection(base_name, target_api, deadline)
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
