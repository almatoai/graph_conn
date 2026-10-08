defmodule GraphConn.Test.ActionWsReopen do
  @moduledoc """
  Drops the shared action invoker's action-ws socket under a refused reopen, and waits for it to
  come back, for tests that drive the reopen path.
  """

  import ExUnit.Assertions

  alias GraphConn.Mock

  # How late a scheduled reopen may run before it counts as never having run.
  @reopen_slack_ms 2_000
  @drop_noticed_ms 1_000

  @doc """
  Kills the invoker's action-ws socket and has the Graph answer its reopen with `status`, then
  waits until that refusal has been stamped as a pending reopen.
  """
  @spec refuse_next_reopen(status :: pos_integer(), retry_after_seconds :: pos_integer()) :: :ok
  def refuse_next_reopen(status, retry_after_seconds) do
    conn_pid = conn_pid()
    assert is_pid(conn_pid)

    Mock.reject_ws_upgrade("standalone", 1, status, retry_after_seconds)
    Process.exit(conn_pid, :kill)

    # The reopen runs on the backoff curve, which carries on from the last drop when the socket
    # was up for less than the stability window, so its delay is read rather than assumed.
    reopen_due_at = _await_reopen_due_at(System.monotonic_time(:millisecond) + @drop_noticed_ms)
    _await_pending_reopen(reopen_due_at + @reopen_slack_ms)
  end

  @doc "The invoker's live action-ws socket, or `nil` while it has none."
  @spec conn_pid :: pid() | nil
  def conn_pid do
    ActionInvoker
    |> :ets.lookup({:"action-ws", :conn_pid})
    |> case do
      [{_key, conn_pid}] -> conn_pid
      [] -> nil
    end
  end

  @doc "Waits until the invoker has an action-ws socket again, flunking at `deadline`."
  @spec await_ws_connection(deadline :: integer()) :: :ok
  def await_ws_connection(deadline) do
    cond do
      is_pid(conn_pid()) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(50)
        await_ws_connection(deadline)

      true ->
        flunk("ActionInvoker never got its action-ws connection back")
    end
  end

  defp _await_reopen_due_at(deadline) do
    ActionInvoker
    |> :ets.lookup({:"action-ws", :reopen_due_at})
    |> case do
      [{_key, reopen_due_at}] when is_integer(reopen_due_at) ->
        reopen_due_at

      _not_scheduled_yet ->
        assert System.monotonic_time(:millisecond) < deadline, "no reopen was scheduled"
        Process.sleep(10)
        _await_reopen_due_at(deadline)
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
end
