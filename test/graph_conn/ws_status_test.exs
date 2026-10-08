defmodule GraphConn.WsStatusTest do
  use ExUnit.Case, async: false

  alias GraphConn.Mock
  alias GraphConn.Test.ActionWsReopen

  setup do
    :ok = ActionWsReopen.await_ws_connection(System.monotonic_time(:millisecond) + 15_000)

    on_exit(fn ->
      Mock.clear_rate_limit({:ws_upgrade, "standalone"})
      ActionWsReopen.await_ws_connection(System.monotonic_time(:millisecond) + 15_000)
    end)

    :ok
  end

  describe "ws_status/2" do
    test "is :connected once the WebSocket is open" do
      assert :connected == GraphConn.ws_status(ActionInvoker, :"action-ws")
    end

    test "is :disconnected after the socket was killed and before it reopens" do
      :ok = ActionWsReopen.refuse_next_reopen(429, 2)

      assert :disconnected == GraphConn.ws_status(ActionInvoker, :"action-ws")
    end

    test "is :disconnected once the socket is dead, even before the manager has noticed" do
      manager = Module.concat(ActionInvoker, "ConnectionManager")
      conn_pid = ActionWsReopen.conn_pid()
      ref = Process.monitor(conn_pid)

      :ok = :sys.suspend(manager)
      on_exit(fn -> :sys.resume(manager) end)
      Process.exit(conn_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^conn_pid, :killed}

      assert :disconnected == GraphConn.ws_status(ActionInvoker, :"action-ws")
      :ok = :sys.resume(manager)
    end

    test "is :disconnected for an api that was never opened" do
      assert :disconnected == GraphConn.ws_status(ActionInvoker, :"events-ws")
    end

    test "is :disconnected for a client that is not running" do
      assert :disconnected == GraphConn.ws_status(NeverStarted, :"action-ws")
    end
  end
end
