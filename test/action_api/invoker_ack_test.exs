defmodule GraphConn.ActionApi.InvokerAckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias GraphConn.ActionApi.Invoker.State, as: InvokerState
  alias GraphConn.Mock
  alias GraphConn.Test.ActionWsReopen

  setup do
    cleanup = fn ->
      Mock.clear_rate_limit({:ws_upgrade, "standalone"})
      ActionWsReopen.await_ws_connection(System.monotonic_time(:millisecond) + 15_000)
    end

    on_exit(cleanup)

    :ok
  end

  describe "acking a result that cannot be sent" do
    test "logs which ack was dropped instead of killing the callback process" do
      # An ack has no caller to answer, so it deliberately does NOT get the 3-tuple the request
      # send returns. It runs in a graph_conn-owned process, and hard-matching here used to take
      # that process down and lose the ack with it.
      ActionWsReopen.refuse_next_reopen(429, 2)

      msg = %{
        "type" => "sendActionResult",
        "id" => "req-that-cannot-be-acked",
        "result" => ~s({"ok":true})
      }

      logged = fn ->
        ActionInvoker.handle_message(:"action-ws", msg, %InvokerState{})
      end

      {result, log} = with_log(logged)

      assert :ok == result
      assert log =~ "Could not ack req-that-cannot-be-acked"

      # The server re-sending is the recovery path, so the log has to say so.
      assert log =~ "re-send"
    end
  end
end
