defmodule GraphConn.ActionApi.InvokerDuplicateResponseTest do
  @moduledoc """
  A response frame nobody waits for, as a second copy of an already answered result is.
  """

  use ExUnit.Case, async: false

  alias GraphConn.ActionApi.Invoker.RequestRegistry
  alias GraphConn.Mock
  alias GraphConn.Test.NilMissInvoker

  # Far under the ~5 s `RequestRegistry.respond/5` spends retrying an id it gets `nil` for.
  @prompt_ms 1_000

  describe "on the default local registry" do
    test "a response nobody waits for does not hold up the next response on the socket" do
      orphan_id = UUID.uuid4()
      marker = UUID.uuid4()
      ws_connection = _ws_connection(ActionInvoker)

      _push_result(ws_connection, orphan_id)

      # The invoker acks before it delivers, so the ack means the orphan's delivery has started.
      assert :ok == _await(fn -> Mock.acknowledged?(orphan_id) end)

      params = %{"other_handler" => "Echo", "command" => marker, "timeout" => 5}
      ticket_id = UUID.uuid4()
      ah_id = _ah_id()
      execute = fn -> ActionInvoker.execute(ticket_id, ah_id, "ExecuteCommand", params) end
      {elapsed_ms, result} = :timer.tc(execute, :millisecond)

      assert {:ok, %{"command" => ^marker}} = result
      assert elapsed_ms < @prompt_ms, "the live response took #{elapsed_ms} ms"
      # A miss there is `[]`, not `nil`, so nothing is retried at all.
      assert [] == _retrying_deliveries(ws_connection)
    end
  end

  describe "on a registry answering a miss with nil" do
    setup do
      config = Application.get_env(:graph_conn, GraphConn.TestConn)
      start_supervised!({NilMissInvoker, config})
      connected? = fn -> NilMissInvoker |> _ws_connection() |> is_pid() end
      assert :ok == _await(connected?, 5_000)
      :ok
    end

    test "a response nobody waits for does not hold up the next frame on the socket" do
      orphan_id = UUID.uuid4()
      next_id = UUID.uuid4()
      ws_connection = _ws_connection(NilMissInvoker)

      _push_result(ws_connection, orphan_id)
      assert :ok == _await(fn -> Mock.acknowledged?(orphan_id) end)
      assert :ok == _await(fn -> [] != _retrying_deliveries(ws_connection) end)

      started_at = System.monotonic_time(:millisecond)
      _push_result(ws_connection, next_id)
      assert :ok == _await(fn -> Mock.acknowledged?(next_id) end)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert elapsed_ms < @prompt_ms, "the next frame was handled after #{elapsed_ms} ms"
      # Still retrying: the next frame did not simply wait until the orphan gave up.
      assert [_orphan, _next] = _retrying_deliveries(ws_connection)
      refute _in_respond?(ws_connection)
    end
  end

  # Delivered as gun delivers a text frame, so it takes the socket process's own path.
  defp _push_result(ws_connection, request_id) do
    %{conn_pid: conn_pid} = :sys.get_state(ws_connection)

    frame =
      %{"type" => "sendActionResult", "id" => request_id, "result" => ~s({"ok":true})}
      |> Jason.encode!()

    send(ws_connection, {:gun_ws, conn_pid, make_ref(), {:text, frame}})
  end

  defp _ws_connection(invoker) do
    invoker
    |> :ets.lookup({:"action-ws", :conn_pid})
    |> case do
      [{_key, conn_pid}] -> conn_pid
      [] -> nil
    end
  end

  # Only the per-frame processes this socket spawned, so another invoker's retries never count.
  defp _retrying_deliveries(ws_connection) do
    Process.list()
    |> Enum.filter(fn pid -> _spawned_by?(pid, ws_connection) and _in_respond?(pid) end)
  end

  defp _spawned_by?(pid, ws_connection),
    do: {:parent, ws_connection} == Process.info(pid, :parent)

  defp _in_respond?(pid) do
    pid
    |> Process.info(:current_stacktrace)
    |> case do
      {:current_stacktrace, stacktrace} ->
        Enum.any?(stacktrace, &match?({RequestRegistry, :respond, _arity, _location}, &1))

      nil ->
        false
    end
  end

  defp _await(check, timeout_ms \\ 2_000),
    do: _await_until(check, System.monotonic_time(:millisecond) + timeout_ms)

  defp _await_until(check, deadline) do
    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        Process.sleep(10)
        _await_until(check, deadline)
    end
  end

  defp _ah_id do
    ActionInvoker.available_applicabilities()
    |> Map.keys()
    |> hd()
  end
end
