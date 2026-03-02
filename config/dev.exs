import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  level: :info

config :graph_conn, insecure: true

config :graph_conn, ActionInvoker,
  # url: "http://localhost:4711",
  url: "http://localhost:8081",
  insecure: true,
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
    ]
  ]

config :graph_conn, ActionHandler,
  # url: "http://localhost:4712",
  url: "http://localhost:8081",
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

config :graph_conn, :mock,
  capabilities: %{
    "ExecuteLocalCommand" => %{
      "description" => "this one executes commands on the same machine where AH is running",
      "mandatoryParameters" => %{
        "command" => %{"description" => "command to execute"}
      },
      "optionalParameters" => %{
        "timeout" => %{"default" => "5", "description" => "timeout in seconds"}
      }
    },
    "ExecuteWindowsCommand" => %{
      "description" => "this one executes commands on crappy Windows machines",
      "mandatoryParameters" => %{
        "host" => %{"description" => "hostname to execute command on"},
        "transport" => %{"default" => "ssl", "description" => "ssl or plain"},
        "command_type" => %{"default" => "cmd", "description" => "command type CMD or PS"},
        "command" => %{"description" => "command to execute"}
      },
      "optionalParameters" => %{
        "timeout" => %{"default" => "120", "description" => "timeout in seconds"}
      }
    },
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
    "HTTPRequest" => %{
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
  applicabilities: %{"action_handler" => %{}}
