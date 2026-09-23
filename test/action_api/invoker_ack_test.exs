defmodule GraphConn.ActionApi.InvokerAckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias GraphConn.ActionApi.Invoker.State, as: InvokerState
  alias GraphConn.Mock

  setup do
    on_exit(fn ->
      Mock.clear_rate_limit({:ws_upgrade, "standalone"})
      _await_ws_connection(System.monotonic_time(:millisecond) + 15_000)
    end)

    :ok
  end

  describe "acking a result that cannot be sent" do
    test "logs which ack was dropped instead of killing the callback process" do
      # An ack has no caller to answer, so it deliberately does NOT get the 3-tuple the request
      # send returns. It runs in a graph_conn-owned process, and hard-matching here used to take
      # that process down and lose the ack with it.
      _refuse_next_reopen()

      msg = %{
        "type" => "sendActionResult",
        "id" => "req-that-cannot-be-acked",
        "result" => ~s({"ok":true})
      }

      {result, log} =
        with_log(fn ->
          ActionInvoker.handle_message(:"action-ws", msg, %InvokerState{})
        end)

      assert :ok == result
      assert log =~ "Could not ack req-that-cannot-be-acked"

      # The server re-sending is the recovery path, so the log has to say so.
      assert log =~ "re-send"
    end
  end

  defp _refuse_next_reopen do
    conn_pid = _conn_pid()
    assert is_pid(conn_pid)

    Mock.reject_ws_upgrade("standalone", 1, 429, 2)
    Process.exit(conn_pid, :kill)
    _await_pending_reopen(System.monotonic_time(:millisecond) + 5_000)
  end

  defp _conn_pid do
    ActionInvoker
    |> :ets.lookup({:"action-ws", :conn_pid})
    |> case do
      [{_key, conn_pid}] -> conn_pid
      [] -> nil
    end
  end

  defp _await_pending_reopen(deadline) do
    ActionInvoker
    |> :ets.lookup({:"action-ws", :reopen_at})
    |> case do
      [{_key, reopen_at}] when is_integer(reopen_at) ->
        :ok

      _not_pending_yet ->
        assert System.monotonic_time(:millisecond) < deadline, "no reopen was marked pending"
        Process.sleep(10)
        _await_pending_reopen(deadline)
    end
  end

  # The invoker is shared with the rest of the suite, so put its connection back.
  defp _await_ws_connection(deadline) do
    cond do
      is_pid(_conn_pid()) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(50)
        _await_ws_connection(deadline)

      true ->
        flunk("ActionInvoker never got its action-ws connection back")
    end
  end
end
