import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  level: :info

config :graph_conn, insecure: true

config :graph_conn, ActionInvoker,
  url: System.get_env("INVOKER_URL", "http://localhost:4711"),
  # url: "http://localhost:8081",
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
  url: System.get_env("HANDLER_URL", "http://localhost:4712"),
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
