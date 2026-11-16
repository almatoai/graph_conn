defmodule GraphConn.ActionApi.ParamsLogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  describe "executing an action, logged at debug" do
    test "keeps the params out of the invoker's log" do
      secret = _secret()
      params = %{"password" => secret}

      execute = fn ->
        request_id = UUID.uuid4()
        ActionInvoker.execute(request_id, "ah_id", "nack", params, ack_timeout: 1)
      end

      log = capture_log([level: :debug], execute)

      assert log =~ "[ActionInvoker] Executing nack on ah_id"
      refute log =~ secret
    end

    test "keeps the params out of the handler's log" do
      secret = _secret()
      params = %{"other_handler" => "Echo", "command" => "ls", "password" => secret}
      ah_id = _ah_id()

      execute = fn ->
        request_id = UUID.uuid4()

        assert {:ok, %{"password" => ^secret}} =
                 ActionInvoker.execute(request_id, ah_id, "ExecuteCommand", params)
      end

      log = capture_log([level: :debug], execute)

      assert log =~ "[ActionHandler] Executing \"ExecuteCommand\""
      refute log =~ secret
    end
  end

  describe "an action whose params match no execute/3 clause, logged at debug" do
    test "keeps the params out of the crash log and the error sent back" do
      secret = _secret()
      params = %{"password" => secret}
      ah_id = _ah_id()

      execute = fn ->
        request_id = UUID.uuid4()
        ActionInvoker.execute(request_id, ah_id, "ExecuteCommand", params)
      end

      {result, log} = with_log([level: :debug], execute)

      assert {:error, _req_id, %{"action_error" => "Execution failed: ** (FunctionClauseError)"}} =
               result

      assert log =~ "FunctionClauseError"
      refute log =~ secret
    end
  end

  describe "an action whose params cannot be encoded, logged at debug" do
    test "is refused at once, without logging the params" do
      secret = _secret()
      params = %{"credentials" => {"user", secret}}
      ah_id = _ah_id()

      execute = fn ->
        request_id = UUID.uuid4()
        ActionInvoker.execute(request_id, ah_id, "ExecuteCommand", params, ack_timeout: 5_000)
      end

      {{elapsed, result}, log} =
        with_log([level: :debug], fn -> :timer.tc(execute, :millisecond) end)

      assert {:error, _req_id, {:not_sent, :unencodable_body}} = result
      assert elapsed < 1_000
      refute log =~ secret
    end
  end

  # Unique per test, so no other test's log line can carry it.
  defp _secret,
    do: "s3cret-" <> UUID.uuid4()

  defp _ah_id do
    ActionInvoker.available_applicabilities()
    |> Map.keys()
    |> hd()
  end
end
