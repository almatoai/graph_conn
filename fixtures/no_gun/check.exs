# Run by check.sh inside the no-gun fixture project.
defmodule NoGun.Check do
  @moduledoc "Asserts what a consumer gets with each VARIANT of graph_conn's optional deps."

  alias GraphConn.Request
  alias GraphConn.Test.MockServer

  @ws_users [GraphConn.EventHandler, GraphConn.ActionApi.Handler, GraphConn.ActionApi.Invoker]
  @expected ~s(Add {:gun, "~> 2.1"} to your deps.)
  # Not graph_conn's own test port, so this can run beside its suite.
  @mock_server_port 18_093

  @spec run() :: :ok
  def run do
    {:module, NoGun.RestClient} = Code.ensure_compiled(NoGun.RestClient)
    IO.puts("ok: REST-only client compiled")

    "VARIANT"
    |> System.get_env()
    |> _check()
  end

  defp _check("bare") do
    for optional <- [:gun, Cachex, Plug.Cowboy],
        Code.ensure_loaded?(optional),
        do: raise("#{inspect(optional)} is loadable, so this check proves nothing")

    {:ok, _started} = Application.ensure_all_started(:graph_conn)
    IO.puts("ok: :graph_conn started without gun, cachex and plug_cowboy")
  end

  defp _check("with_gun") do
    if Code.ensure_loaded?(Cachex), do: raise("cachex is loadable, so this check proves nothing")
    {:module, :gun} = Code.ensure_loaded(:gun)
    # Proves graph_conn's test/support was built here, with its cachex-only modules left out.
    {:module, GraphConn.Test.EventHandler} = Code.ensure_loaded(GraphConn.Test.EventHandler)
    false = Code.ensure_loaded?(TestActionHandler)
    IO.puts("ok: graph_conn's test/support built with gun and without cachex")
  end

  defp _check(unknown) when unknown != nil,
    do: raise("Unknown VARIANT: #{inspect(unknown)}")

  defp _check(nil) do
    if Code.ensure_loaded?(:gun), do: raise("gun is loadable, so this check proves nothing")

    Enum.each(@ws_users, &_assert_compile_fails/1)
    _assert_open_ws_raises()
    _assert_execute_ws_raises()
  end

  defp _assert_compile_fails(ws_user) do
    "defmodule NoGun.WsUser do use #{inspect(ws_user)} end"
    |> Code.compile_string("no_gun_ws_user.ex")

    raise "use #{inspect(ws_user)} compiled without gun"
  rescue
    error in CompileError ->
      _assert_message(error.description, "use #{inspect(ws_user)}")
  end

  defp _assert_open_ws_raises do
    GraphConn.open_ws_connection(NoGun.RestClient, :"events-ws")
    raise "open_ws_connection/2 did not raise without gun"
  rescue
    error in RuntimeError -> _assert_message(error.message, "open_ws_connection/2")
  end

  # A REST-only client that is up and running, asked to execute on a WebSocket api.
  defp _assert_execute_ws_raises do
    {:ok, _mock_server} = MockServer.start_link(port: @mock_server_port)
    # Long enough for execute/3 to wait out the client's start-up instead of polling for it here.
    Application.put_env(:graph_conn, :startup_wait_ms, 10_000)

    :ok =
      {:no_gun, NoGun.RestClient}
      |> MockServer.inject_local_config(:valid_invoker_credentials,
        port: @mock_server_port
      )

    {:ok, _client} = NoGun.RestClient.start_supervisor(:from_config)

    request = %Request{body: %{}}
    GraphConn.execute(NoGun.RestClient, :"events-ws", request)
    raise "execute/3 on a WebSocket api did not raise without gun"
  rescue
    error in RuntimeError -> _assert_message(error.message, "execute/3 on events-ws")
  end

  defp _assert_message(message, subject) do
    if String.contains?(message, @expected),
      do: IO.puts("ok: #{subject} -> #{message}"),
      else: raise("#{subject} failed with an unexpected message: #{message}")
  end
end

NoGun.Check.run()
