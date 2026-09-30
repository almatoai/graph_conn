defmodule GraphConn.WsCloseTest do
  use ExUnit.Case, async: false

  alias GraphConn.{Mock, TestClient, TestConn}

  setup do
    TestClient.stop()
    on_exit(&TestClient.stop/0)

    assert {:ok, _sup_pid} = TestClient.start()
    assert_receive {:conn_status_changed, :ready}, 15_000
    GraphConn.open_ws_connection(TestConn, :"action-ws")
    assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000

    [{_key, ws_connection}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})
    assert :ok = _await_mock_socket(System.monotonic_time(:millisecond) + 5_000)
    {:ok, ws_connection: ws_connection}
  end

  # The mock registers its side of the socket a moment after the client sees the upgrade.
  defp _await_mock_socket(deadline) do
    cond do
      [] != Registry.lookup(Registry.TestSockets, {:client, "invoker"}) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the mock never registered the socket")

      true ->
        Process.sleep(10)
        _await_mock_socket(deadline)
    end
  end

  for code <- [1000, 1001] do
    @code code

    test "a #{code} close from the server shuts the socket down rather than crashing it",
         %{ws_connection: ws_connection} do
      monitor = Process.monitor(ws_connection)
      Mock.close_ws_connection("invoker", @code, "going away")

      assert_receive {:DOWN, ^monitor, :process, ^ws_connection,
                      {:shutdown, "server sent close request: going away"}}

      assert_receive {:conn_status_changed, :"action-ws", {:shutdown, _reason}}
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
    end
  end

  test "any other close from the server still ends the socket abnormally",
       %{ws_connection: ws_connection} do
    monitor = Process.monitor(ws_connection)
    Mock.close_ws_connection("invoker", 1011, "internal error")

    assert_receive {:DOWN, ^monitor, :process, ^ws_connection,
                    "server sent close request: internal error"}
  end
end
