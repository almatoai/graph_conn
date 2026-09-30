defmodule GraphConn.HelloTest do
  use ExUnit.Case, async: false

  alias GraphConn.ActionApi.Responder
  alias GraphConn.Request

  # What the mock's `hello` advertises to the "handler" client, set in config/test.exs.
  @handler_limit 200_000

  describe "max_frame_bytes/2" do
    test "is the limit the server advertised in hello" do
      assert @handler_limit == GraphConn.max_frame_bytes(TestActionHandler, :"action-ws")
    end

    test "falls back to 1_000_000 when hello advertises no limit" do
      assert 1_000_000 == GraphConn.max_frame_bytes(ActionInvoker, :"action-ws")
    end

    test "falls back to 1_000_000 for a client that is not running" do
      assert 1_000_000 == GraphConn.max_frame_bytes(NeverStarted, :"action-ws")
    end

    test "keeps the last advertised limit while the connection is down" do
      on_exit(fn -> _await_limit(@handler_limit, _deadline()) end)

      GraphConn.Mock.close_ws_connection("handler", 1000, "test drop")
      _await_dropped(_deadline())

      assert @handler_limit == GraphConn.max_frame_bytes(TestActionHandler, :"action-ws")
    end

    test "goes back to the fallback when a reconnect's hello advertises no limit" do
      on_exit(fn -> _reconnect_handler_with_limit(@handler_limit) end)

      _reconnect_handler_with_limit(nil)

      assert 1_000_000 == GraphConn.max_frame_bytes(TestActionHandler, :"action-ws")
    end
  end

  describe "the mock server" do
    test "accepts a frame above 1 MB when its hello advertises more" do
      on_exit(fn -> _reconnect_handler_with_limit(@handler_limit) end)
      _reconnect_handler_with_limit(4_194_304)

      req_id = UUID.uuid4()
      {:ok, _owner} = Registry.register(Registry.TestSockets, req_id, {})
      result = Jason.encode!(%{data: String.duplicate("a", 1_500_000)})

      %Request{body: %{id: req_id, type: "sendActionResult", result: result}}
      |> Responder.return_response(TestActionHandler, 3_000)

      assert_receive frame when is_binary(frame)
      assert %{"result" => ^result} = Jason.decode!(frame)
    end
  end

  describe "clientHello" do
    test "a malformed client_hello refuses to start the client" do
      on_exit(&GraphConn.TestClient.stop/0)
      Process.flag(:trap_exit, true)

      assert {:error,
              {:shutdown,
               {:failed_to_start_child, GraphConn.ConnectionManager,
                {%ArgumentError{message: "invalid :app in :client_hello" <> _rest}, _stack}}}} =
               GraphConn.TestClient.start(client_hello: [client: [app: :not_a_string]])
    end

    test "announces the client the handler is configured with" do
      assert %{type: "clientHello", client: %{app: "graph-conn-test", version: "0.0.1"}} =
               GraphConn.Mock.client_hello("handler")
    end

    test "is not sent by a client that configures none" do
      assert nil == GraphConn.Mock.client_hello("standalone")
    end
  end

  defp _reconnect_handler_with_limit(limit) do
    GraphConn.Mock.put_hello_max_frame_bytes("handler", limit)
    GraphConn.Mock.close_ws_connection("handler", 1000, "test reconnect")

    expected = limit || 1_000_000
    _await_limit(expected, _deadline())
  end

  defp _deadline,
    do: System.monotonic_time(:millisecond) + 10_000

  defp _await_dropped(deadline) do
    cond do
      [{{:"action-ws", :conn_pid}, nil}] ==
          :ets.lookup(TestActionHandler, {:"action-ws", :conn_pid}) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("handler connection did not drop")

      true ->
        Process.sleep(5)
        _await_dropped(deadline)
    end
  end

  defp _await_limit(expected, deadline) do
    cond do
      expected == GraphConn.max_frame_bytes(TestActionHandler, :"action-ws") and
        :ready == TestActionHandler.status() and _handler_connected?() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("handler did not reconnect with a #{expected} byte limit")

      true ->
        Process.sleep(50)
        _await_limit(expected, deadline)
    end
  end

  defp _handler_connected? do
    Registry.TestSockets
    |> Registry.lookup({:client, "handler"})
    |> Kernel.!=([])
  end
end
