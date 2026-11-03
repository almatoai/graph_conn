alias GraphConn.Test.ProxyFixture

start_proxy = "Start it with `docker compose -f docker-compose.test.yaml up -d`."

proxy_exclusions =
  cond do
    ProxyFixture.reachable?() ->
      []

    System.get_env("REQUIRE_PROXY_TESTS") == "true" ->
      message =
        "REQUIRE_PROXY_TESTS is set but nothing is listening on port #{ProxyFixture.port()}. "

      raise message <> start_proxy

    true ->
      IO.puts("Excluding proxy tests: no proxy on port #{ProxyFixture.port()}. " <> start_proxy)
      [:proxy]
  end

ExUnit.start(exclude: [:skip, :integration] ++ proxy_exclusions, assert_receive_timeout: 5_000)

unless System.get_env("INTEGRATION_TESTS") == "true" do
  mock_server = [port: Application.fetch_env!(:graph_conn, :mock_server_port)]

  :ok =
    {:graph_conn, GraphConn.TestConn}
    |> GraphConn.Test.MockServer.inject_local_config(:valid_invoker_credentials, mock_server)

  :ok =
    {:graph_conn, GraphConn.Test.ActionHandler}
    |> GraphConn.Test.MockServer.inject_local_config(:valid_handler_credentials, mock_server)

  {:ok, _mock_server} = GraphConn.Test.MockServer.start_link(mock_server)
end

:graph_conn
|> Application.get_env(GraphConn.Test.ActionHandler)
|> TestActionHandler.start_link()

:graph_conn
|> Application.get_env(GraphConn.Test.EventHandler)
|> GraphConn.Test.EventHandler.start_link()

# Its own credentials, so a rate limit armed for `GraphConn.TestConn` cannot deny this one.
standalone_credentials = GraphConn.Test.MockServer.valid_standalone_invoker_credentials()

invoker_auth =
  :graph_conn
  |> Application.get_env(GraphConn.TestConn)
  |> Keyword.fetch!(:auth)
  |> Keyword.put(:credentials, standalone_credentials)

:graph_conn
|> Application.get_env(GraphConn.TestConn)
|> Keyword.put(:auth, invoker_auth)
|> ActionInvoker.start_link()

Process.sleep(1900)
