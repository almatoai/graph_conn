import Config

config :ex_unit,
  capture_log: true

# Its own port, so this suite and a consumer's suite on the mock server's default 8081 can run at
# the same time. Override with GRAPH_CONN_TEST_PORT.
mock_server_port =
  "GRAPH_CONN_TEST_PORT"
  |> System.get_env("18081")
  |> String.to_integer()

config :graph_conn, insecure: true, mock_server_port: mock_server_port

# config :graph_conn,
#   insecure: true,
#   proxy: [
#     address: "localhost",
#     port: "3128",
#     transport: "tcp", # or "tls"
#     insecure: "true"
#   ]

config :graph_conn, GraphConn.TestConn,
  url: "http://localhost:#{mock_server_port}",
  # auto_connect: true, # true | false | :just_versions
  insecure: true,
  timeout: 30_000,
  ws_ping: [
    interval_in_ms: 2_000,
    reconnect_after_missing_pings: 3
  ],
  auth: [
    credentials: [
      client_id: "action_invoker",
      client_secret: "action_invoker_secret",
      username: "action_invoker_username",
      password: "action_invoker_password"
    ],
    timeout: 45_000
  ]

config :graph_conn, ActionHandler,
  url: "http://localhost:#{mock_server_port}",
  insecure: true,
  ws_ping: [
    interval_in_ms: 2_000,
    reconnect_after_missing_pings: 3
  ],
  auth: [
    credentials: [
      client_id: "action_handler",
      client_secret: "action_handler_secret",
      username: "action_handler_username",
      password: "action_handler_password"
    ]
  ]

config :graph_conn, GraphConn.Test.EventHandler,
  url: "http://localhost:#{mock_server_port}",
  insecure: true,
  ws_ping: [
    interval_in_ms: 2_000,
    reconnect_after_missing_pings: 3
  ],
  auth: [
    credentials: [
      client_id: "event_handler",
      client_secret: "event_handler_secret",
      username: "event_handler_username",
      password: "event_handler_password"
    ]
  ]

config :graph_conn, :mock,
  capabilities: %{
    "ExecuteCommand" => %{
      "description" => "this one executes commands",
      "mandatoryParameters" => %{
        "command" => %{"description" => "command to execute"},
        "host" => %{"description" => "hostname to execute command on"}
      },
      "optionalParameters" => %{
        "timeout" => %{"default" => "120", "description" => "timeout in seconds"}
      }
    },
    "RunScript" => %{
      "description" => "this one executes scripts",
      "mandatoryParameters" => %{"command" => %{"description" => "script to run"}},
      "optionalParameters" => %{
        "timeout" => %{"default" => "120", "description" => "timeout in seconds"},
        "workdir" => %{
          "default" => "/tmp",
          "description" => "working directory for the script"
        }
      }
    },
    "HTTP" => %{
      "description" => "this one invokes HTTP call",
      "mandatoryParameters" => %{
        "method" => %{"default" => "GET", "description" => "HTTP method"},
        "url" => %{"description" => "url to hit"}
      },
      "optionalParameters" => %{
        "timeout" => %{"default" => "120", "description" => "timeout in seconds"}
      }
    }
  },
  applicabilities: %{"action_handler" => %{}},
  hello_max_frame_bytes: %{"handler" => 200_000}

config :graph_conn, GraphConn.Test.ActionHandler,
  client_hello: [client: [app: "graph-conn-test", version: "0.0.1"]]
