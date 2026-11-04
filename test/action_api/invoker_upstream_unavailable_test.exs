defmodule GraphConn.ActionApi.InvokerUpstreamUnavailableTest do
  @moduledoc """
  What an invoker does when the gateway answers a request with a `503` on the open socket.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias GraphConn.ActionApi.Invoker.RequestRegistry
  alias GraphConn.ActionApi.Invoker.State, as: InvokerState
  alias GraphConn.{Mock, TestClient}

  @params %{"command" => "ls", "host" => "localhost"}

  setup do
    cleanup = fn ->
      Mock.clear_rate_limit({:request_deny, "standalone"})
      Mock.clear_rate_limit({:submit_drop, "standalone"})
    end

    on_exit(cleanup)
    :ok
  end

  test "fails the caller at once with the frame's error map instead of resending the request" do
    # Two armed: a resend would take the second one.
    Mock.fail_next_request_unavailable("standalone", 2)

    {elapsed, result} =
      TestClient.measure(fn -> ActionInvoker.execute("ExecuteCommand", @params) end)

    error = %{"code" => 503, "message" => "Upstream unavailable", "upstream" => "action"}
    assert {:error, request_id, ^error} = result
    assert is_binary(request_id)
    assert elapsed < 3_000
    assert {:ok, :upstream_unavailable} == Mock.take_request_denial("standalone")
  end

  test "names a 503 that carries no request id and answers no caller" do
    request_id = UUID.uuid4()
    :ok = RequestRegistry.register(ActionInvoker, request_id)
    on_exit(fn -> RequestRegistry.unregister(ActionInvoker, request_id) end)

    for frame <- [
          %{"error" => %{"code" => 503, "message" => "Upstream unavailable"}},
          %{"error" => %{"code" => 503, "message" => "Upstream unavailable"}, "id" => nil}
        ] do
      logged = fn -> ActionInvoker.handle_message(:"action-ws", frame, %InvokerState{}) end
      {_returned, log} = with_log(logged)

      assert log =~ "[warning]"
      assert log =~ "Upstream unavailable with no request id"
      refute log =~ "Received unexpected message from action-ws"
    end

    refute_received {_answer, ^request_id, _reason}
  end

  test "names a 503 for a request no caller is waiting on" do
    request_id = UUID.uuid4()

    frame = %{
      "error" => %{"code" => 503, "message" => "Upstream unavailable"},
      "id" => request_id
    }

    logged = fn -> ActionInvoker.handle_message(:"action-ws", frame, %InvokerState{}) end
    {_returned, log} = with_log(logged)

    assert log =~ "[warning]"
    assert log =~ "no waiting caller"
    assert log =~ request_id
    assert log =~ "503"
  end

  test "a 503 landing after the ack answers neither the last call nor the caller's mailbox" do
    # The first send is acked and never answered, so the caller sends a last call.
    Mock.drop_next_submit("standalone", 1)
    params = %{"other_handler" => "Echo", "command" => "ls", "timeout" => 2, "sleep" => 500}
    caller = self()
    late = %{"code" => 503, "message" => "late"}

    # Once while the first send awaits its response, once while the last call awaits its own.
    injector = fn ->
      request_id = _await_registered(caller)

      for sends <- [1, 2] do
        _await_submits(request_id, sends)
        # Acked: the caller has moved on from `_await_ack/4`.
        _await_waiting_for_response(caller, System.monotonic_time(:millisecond) + 5_000)
        frame = %{"error" => late, "id" => request_id}
        ActionInvoker.handle_message(:"action-ws", frame, %InvokerState{})
      end
    end

    spawn_link(injector)

    ah_id = _ah_id()

    result =
      UUID.uuid4()
      |> ActionInvoker.execute(ah_id, "ExecuteCommand", params)

    assert {:ok, %{"command" => "ls"}} = result
    refute_received {:refused, _request_id, ^late}
  end

  defp _await_registered(caller) do
    ActionInvoker
    |> RequestRegistry.name()
    |> Registry.select([{{:"$1", :"$2", :_}, [{:==, :"$2", caller}], [:"$1"]}])
    |> case do
      [request_id] ->
        request_id

      [] ->
        Process.sleep(10)
        _await_registered(caller)
    end
  end

  # The mock's socket registers under a request's id once per submit it takes.
  defp _await_submits(request_id, sends) do
    registered =
      Registry.TestSockets
      |> Registry.lookup(request_id)
      |> length()

    if registered < sends do
      Process.sleep(10)
      _await_submits(request_id, sends)
    end
  end

  defp _await_waiting_for_response(caller, deadline) do
    caller
    |> Process.info(:current_function)
    |> case do
      {:current_function, {ActionInvoker, :_wait_for_response, 2}} ->
        :ok

      _elsewhere ->
        assert System.monotonic_time(:millisecond) < deadline, "caller never awaited a response"
        Process.sleep(10)
        _await_waiting_for_response(caller, deadline)
    end
  end

  defp _ah_id do
    ActionInvoker.available_applicabilities()
    |> Map.keys()
    |> hd()
  end
end
