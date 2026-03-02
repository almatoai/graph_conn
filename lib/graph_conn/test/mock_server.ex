defmodule GraphConn.Test.MockServer do
  @moduledoc false
  require Logger
  alias GraphConn.Test
  use Supervisor

  @default_port 8081

  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(config \\ []),
    do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @impl Supervisor
  def init(config) do
    port = Keyword.get(config, :port, @default_port)

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

  @spec inject_local_config({atom(), module()}, atom(), Keyword.t()) :: :ok
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
