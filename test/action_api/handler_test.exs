defmodule GraphConn.ActionApi.HandlerTest do
  use ExUnit.Case, async: false

  describe "status/0" do
    test "is :ready when ws connection is established" do
      assert :ready = TestActionHandler.status()
    end
  end

  test "ah execution is run in parallel" do
    # Each execution adds processes that go away once it has answered. Run one at a time, 10
    # executions of 100ms cannot all answer in under a second; the deadline sits below that.
    procs_before = :erlang.processes() |> MapSet.new()
    params = %{"other_handler" => "Echo", "command" => "ls", "sleep" => 100}
    executions = 10
    deadline = System.monotonic_time(:millisecond) + 800

    for _ <- 1..executions do
      spawn(fn ->
        assert {:ok, %{"other_handler" => "Echo", "command" => "ls", "timeout" => _}} =
                 ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params)
      end)
    end

    assert :ok == _await_no_new_processes(procs_before, deadline)
  end

  test "second action call with the same req_id is waiting for first execution to finish" do
    params = %{"other_handler" => "Echo", "command" => "ls", "sleep" => 40}
    executions = 3
    req_id = UUID.uuid4()

    for _ <- 1..executions do
      spawn(fn ->
        assert {:ok, %{"other_handler" => "Echo", "command" => "ls", "timeout" => _}} =
                 ActionInvoker.execute(req_id, _ah_id(), "ExecuteCommand", params)
      end)
    end

    Process.sleep(100)
  end

  test "second action call with the same req_id is returing cached result" do
    params = %{"other_handler" => "Echo", "command" => "ls", "sleep" => 40}
    executions = 3
    req_id = UUID.uuid4()

    for _ <- 1..executions do
      assert {:ok, %{"other_handler" => "Echo", "command" => "ls", "timeout" => _}} =
               ActionInvoker.execute(req_id, _ah_id(), "ExecuteCommand", params)
    end
  end

  defp _await_no_new_processes(procs_before, deadline) do
    :erlang.processes()
    |> MapSet.new()
    |> MapSet.difference(procs_before)
    |> MapSet.size()
    |> _no_new_processes(System.monotonic_time(:millisecond), procs_before, deadline)
  end

  defp _no_new_processes(0, _now, _procs_before, _deadline),
    do: :ok

  defp _no_new_processes(left, now, _procs_before, deadline) when now >= deadline,
    do: {:still_running, left}

  defp _no_new_processes(_left, _now, procs_before, deadline) do
    Process.sleep(10)
    _await_no_new_processes(procs_before, deadline)
  end

  defp _ah_id do
    ActionInvoker.available_applicabilities()
    |> Map.keys()
    |> hd()
  end
end
