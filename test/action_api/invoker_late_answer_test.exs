defmodule GraphConn.ActionApi.InvokerLateAnswerTest do
  @moduledoc """
  What an invoker does with an answer that reaches the caller after the wait it answers gave up.
  """

  # Attaches `:logger` handlers, which are global.
  use ExUnit.Case, async: false

  alias GraphConn.ActionApi.Invoker.RequestRegistry
  alias GraphConn.{Mock, TestClient}
  alias GraphConn.Test.LogTrigger

  @ah_id "ah_app_id_cls303dzz11yn0150m5qnmlrx"
  @ack_timeout 300
  @retry_after_ms 1_986
  @unavailable %{"code" => 503, "message" => "Upstream unavailable"}

  setup do
    cleanup = fn ->
      Mock.clear_rate_limit({:request_deny, "standalone"})
      Mock.clear_rate_limit({:submit_drop, "standalone"})
    end

    on_exit(cleanup)
    :ok
  end

  describe "a refusal arriving after its send's ack wait timed out" do
    test "fails the request with the advertised wait instead of resending into the limiter" do
      Mock.ignore_next_request("standalone", 1)
      _refuse_after_ack_timeout({:rate_limited, @retry_after_ms})

      {elapsed, result} = TestClient.measure(&_execute/0)

      assert {:error, _request_id, {:rate_limited, @retry_after_ms}} = result
      assert elapsed < @ack_timeout * 2
    end

    test "fails the request with a 503's error map instead of resending to a down upstream" do
      Mock.ignore_next_request("standalone", 1)
      _refuse_after_ack_timeout(@unavailable)

      assert {:error, _request_id, @unavailable} = _execute()
    end

    test "fails the request with the refusal, not an ack timeout, after the last send" do
      Mock.ignore_next_request("standalone", 3)
      _refuse_after_ack_timeout({:rate_limited, @retry_after_ms}, 3)

      assert {:error, _request_id, {:rate_limited, @retry_after_ms}} = _execute()
    end
  end

  describe "a response arriving after the response wait gave up" do
    test "does not answer the next identical execute from the same process, which gets its own" do
      # The first send and its last call are both acked and never answered.
      Mock.drop_next_submit("standalone", 2)
      _respond_after_response_timeout(%{"late" => true})
      ticket_id = UUID.uuid4()

      assert {:error, request_id, {:exec_timeout, 1_000}} = _execute(ticket_id, 1, "Echo")

      assert {:ok, %{"command" => "ls"}} = _execute(ticket_id, 1, "Echo")
      assert [] == _registered(request_id)
    end

    test "answers the last call it lands in front of" do
      # Both sends are acked and never answered, so only the late response can answer.
      Mock.drop_next_submit("standalone", 2)
      late_response = %{"late" => true}
      _respond_on("Sending last call", late_response)

      ticket_id = UUID.uuid4()

      assert {:ok, ^late_response} = _execute(ticket_id, 1)
    end
  end

  defp _execute(ticket_id \\ UUID.uuid4(), timeout_seconds \\ 2, other_handler \\ nil) do
    params =
      %{"command" => "ls", "host" => "localhost", "timeout" => timeout_seconds}
      |> _put_other_handler(other_handler)

    ActionInvoker.execute(ticket_id, @ah_id, "ExecuteCommand", params, ack_timeout: @ack_timeout)
  end

  defp _put_other_handler(params, nil),
    do: params

  defp _put_other_handler(params, other_handler),
    do: Map.put(params, "other_handler", other_handler)

  defp _refuse_after_ack_timeout(reason, nth \\ 1) do
    refuse = fn ->
      request_id = Logger.metadata()[:req_id]
      :ok = RequestRegistry.refused(ActionInvoker, request_id, reason)
    end

    LogTrigger.attach("Message ack timeout", refuse, nth)
  end

  defp _respond_after_response_timeout(response),
    do: _respond_on("Response timeout.", response)

  defp _respond_on(logged, response) do
    respond = fn ->
      request_id = Logger.metadata()[:req_id]
      :ok = RequestRegistry.respond(ActionInvoker, request_id, response)
    end

    LogTrigger.attach(logged, respond)
  end

  defp _registered(request_id) do
    ActionInvoker
    |> RequestRegistry.name()
    |> Registry.lookup(request_id)
  end
end
