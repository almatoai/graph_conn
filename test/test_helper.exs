alias GraphConn.Test.ProxyFixture

proxy_exclusions =
  cond do
    ProxyFixture.reachable?() ->
      []

    System.get_env("REQUIRE_PROXY_TESTS") == "true" ->
      raise "REQUIRE_PROXY_TESTS is set but nothing is listening on port #{ProxyFixture.port()}. " <>
              "Start it with `docker compose -f docker-compose.test.yaml up -d`."

    true ->
      IO.puts(
        "Excluding proxy tests: no proxy on port #{ProxyFixture.port()}. " <>
          "Start it with `docker compose -f docker-compose.test.yaml up -d`."
      )

      [:proxy]
  end

ExUnit.start(
  exclude: [:skip, :integration] ++ proxy_exclusions,
  assert_receive_timeout: 5_000
)

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

  {:ok, _mock_server} = GraphConn.Test.MockServer.start_link()
end

:graph_conn
|> Application.get_env(GraphConn.Test.ActionHandler)
|> TestActionHandler.start_link()

:graph_conn
|> Application.get_env(GraphConn.Test.EventHandler)
|> GraphConn.Test.EventHandler.start_link()

# Its own credentials, so a rate limit armed for `GraphConn.TestConn` cannot deny this one.
invoker_auth =
  :graph_conn
  |> Application.get_env(GraphConn.TestConn)
  |> Keyword.fetch!(:auth)
  |> Keyword.put(:credentials, GraphConn.Test.MockServer.valid_standalone_invoker_credentials())

:graph_conn
|> Application.get_env(GraphConn.TestConn)
|> Keyword.put(:auth, invoker_auth)
|> ActionInvoker.start_link()

Process.sleep(1900)
