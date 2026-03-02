ExUnit.start(exclude: [:skip, :integration], assert_receive_timeout: 5_000)

unless System.get_env("INTEGRATION_TESTS") == "true" do
  :ok =
    GraphConn.Test.MockServer.inject_local_config(
      {:graph_conn, GraphConn.TestConn},
      :valid_invoker_credentials
    )

  :ok =
    GraphConn.Test.MockServer.inject_local_config(
      {:graph_conn, GraphConn.Test.ActionHandler},
      :valid_handler_credentials
    )

  GraphConn.Test.MockServer.start_link()
end

:graph_conn
|> Application.get_env(GraphConn.Test.ActionHandler)
|> TestActionHandler.start_link()

:graph_conn
|> Application.get_env(GraphConn.Test.EventHandler)
|> GraphConn.Test.EventHandler.start_link()

:graph_conn
|> Application.get_env(GraphConn.TestConn)
|> ActionInvoker.start_link()

Process.sleep(1900)
