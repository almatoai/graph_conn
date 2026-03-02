defmodule GraphConn.ActionApi.HandlerTest do
  use ExUnit.Case, async: false

  describe "status/0" do
    test "is :ready when ws connection is established" do
      assert :ready = TestActionHandler.status()
    end
  end

  test "ah execution is run in parallel" do
    # For each execution we get 2 new processes. Cachex.transaction/3 executes block in a single process, so:
    #
    # - If one action is executed at least 40ms (sleep), we'll have only 4 actions finished in 180ms, 
    # thus having 12 processes around.
    # - If all 10 actions are executed in parallel (out of Cachex transaction), 
    # all 10 actions will finish in 180ms and there shouldn't be new processes around.

    procs_before = :erlang.processes() |> MapSet.new()
    params = %{"other_handler" => "Echo", "command" => "ls", "sleep" => 40}
    executions = 10

    for _ <- 1..executions do
      spawn(fn ->
        assert {:ok, %{"other_handler" => "Echo", "command" => "ls", "timeout" => _}} =
                 ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params)
      end)
    end

    Process.sleep(180)

    assert 0 ==
             :erlang.processes()
             |> MapSet.new()
             |> MapSet.difference(procs_before)
             |> Enum.count()
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

  defp _ah_id do
    ActionInvoker.available_applicabilities()
    |> Map.keys()
    |> hd()
  end
end
