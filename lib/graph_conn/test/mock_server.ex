defmodule GraphConn.Test.MockServer do
  @moduledoc """
  Local stand-in for a Graph server, for use by this library's tests and its consumers'.

  Ships in `lib/`, so the default port below is effectively a cross-repo contract: every
  consumer suite that calls `start_link/1` binds it, and two suites therefore cannot run
  concurrently on the default. `start_link/1` waits for the port rather than failing outright,
  which covers a listener still closing from a previous run; genuinely simultaneous suites need
  distinct `:port` values.
  """
  require Logger
  alias GraphConn.Test
  use Supervisor

  @default_port 8081

  # Long enough to outlast a previous run's listener closing, short enough to still fail a build
  # rather than look like a hang when another suite genuinely holds the port.
  @port_wait_attempts 100
  @port_wait_in_ms 100

  @doc """
  Starts the mock server, waiting for its port if a previous run is still releasing it.

  `mix bless` runs its two test passes as back-to-back `mix` subprocesses that both bind this
  port, and on a loaded machine the first pass's listener can still be closing when the second
  starts -- which used to fail the run with `:eaddrinuse`. Waiting here fixes that for every
  consumer without any change on their side.
  """
  @spec start_link(config :: Keyword.t()) :: Supervisor.on_start()
  def start_link(config \\ []) do
    config
    |> Keyword.get(:port, @default_port)
    |> _await_free_port(@port_wait_attempts)

    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  # Binding and immediately closing is the only portable way to ask whether a port is free. The
  # gap before Ranch binds it is a genuine race, but only against a suite starting at the very
  # same moment -- which needs its own port, not a longer wait.
  defp _await_free_port(port, attempts_left) do
    port
    |> :gen_tcp.listen([:binary, {:active, false}])
    |> case do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)

      {:error, reason} when attempts_left > 1 ->
        Logger.warning("Port #{port} is #{inspect(reason)}, waiting for it to free up...")
        Process.sleep(@port_wait_in_ms)
        _await_free_port(port, attempts_left - 1)

      {:error, reason} ->
        Logger.error(
          "Port #{port} still #{inspect(reason)} after " <>
            "#{@port_wait_attempts * @port_wait_in_ms}ms; another suite is holding it."
        )
    end
  end

  @impl Supervisor
  def init(config) do
    port = Keyword.get(config, :port, @default_port)
    # Owned here so `GraphConn.Mock` can decrement an arm atomically; see its `rate_limit_auth/3`.
    _table = :ets.new(GraphConn.Mock, [:named_table, :public, :set])

    children = [
      {Plug.Cowboy,
       scheme: :http, plug: MockRouter, options: [dispatch: _dispatch(), port: port]},
      Registry.child_spec(
        keys: :duplicate,
        name: Registry.TestSockets
      )
    ]

    Logger.info("Starting local test server @ port #{inspect(port)}")
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns credentials for the standalone ActionInvoker used by the action-api tests.

  Deliberately distinct from `valid_invoker_credentials/0`: the two clients would otherwise share
  a client id and a token, so arming a rate limit for one would deny the other.
  """
  @spec valid_standalone_invoker_credentials :: Keyword.t()
  def valid_standalone_invoker_credentials do
    [
      client_id: "standalone_invoker",
      client_secret: "standalone_invoker_secret",
      username: "standalone_invoker_username",
      password: "standalone_invoker_password"
    ]
  end

  @doc """
  Returns credentials that Mock server will accept as valid for any connection
  that will invoke REST only commands or action-ws api in a invoker role.
  """
  @spec valid_invoker_credentials :: Keyword.t()
  def valid_invoker_credentials do
    [
      client_id: "action_invoker",
      client_secret: "action_invoker_secret",
      username: "action_invoker_username",
      password: "action_invoker_password"
    ]
  end

  @doc """
  Returns credentials that Mock server will accept as valid for any connection
  that will invoke REST only commands or action-ws api in a action handler role.
  """
  @spec valid_handler_credentials :: Keyword.t()
  def valid_handler_credentials do
    [
      client_id: "action_handler",
      client_secret: "action_handler_secret",
      username: "action_handler_username",
      password: "action_handler_password"
    ]
  end

  @doc """
  Returns credentials that Mock server will accept as valid for any connection
  that will invoke REST only commands or events-ws api in a events handler role.
  """
  @spec valid_event_handler_credentials :: Keyword.t()
  def valid_event_handler_credentials do
    [
      client_id: "event_handler",
      client_secret: "event_handler_secret",
      username: "event_handler_username",
      password: "event_handler_password"
    ]
  end

  @doc false
  @spec inject_local_config(
          app_mod :: {atom(), module()},
          local_fun_name :: atom(),
          config :: Keyword.t()
        ) :: :ok
  def inject_local_config({app, mod}, local_fun_name, config \\ []) do
    port = Keyword.get(config, :port, @default_port)

    config =
      app
      |> Application.get_env(mod, [])
      |> Keyword.put(:url, "http://localhost:#{port}")
      |> Keyword.put(:transport, :tcp)

    auth_config =
      config
      |> Keyword.get(:auth, [])
      |> Keyword.put(:credentials, apply(__MODULE__, local_fun_name, []))

    config = Keyword.put(config, :auth, auth_config)

    Application.put_env(app, mod, config)
  end

  defp _dispatch do
    [
      {:_,
       [
         {"/api/0.9/action-ws/[...]", Test.MockSocket, []},
         {"/api/6.1/events-ws/[...]", Test.EventsMockSocket, []},
         {:_, Plug.Cowboy.Handler, {Test.MockRouter, []}}
       ]}
    ]
  end
end
