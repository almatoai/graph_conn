defmodule GraphConn.ActionApi.InvokerResultTest do
  use ExUnit.Case, async: false

  alias GraphConn.ActionApi.Invoker.RequestRegistry
  alias GraphConn.ActionApi.Invoker.State, as: InvokerState
  alias GraphConn.Mock

  setup do
    request_id = UUID.uuid4()
    :ok = RequestRegistry.register(ActionInvoker, request_id)
    on_exit(fn -> RequestRegistry.unregister(ActionInvoker, request_id) end)

    {:ok, request_id: request_id}
  end

  describe "receiving an action result" do
    test "decodes a result sent as a JSON-encoded string", %{request_id: request_id} do
      assert :ok == _receive_result(request_id, ~s({"ok":true}))
      assert_receive {:response, ^request_id, %{"ok" => true}}
      assert :ok == _await_acknowledged(request_id)
    end

    test "hands over a result sent as a JSON object as that object", %{request_id: request_id} do
      assert :ok == _receive_result(request_id, %{"ok" => true})
      assert_receive {:response, ^request_id, %{"ok" => true}}
      assert :ok == _await_acknowledged(request_id)
    end

    test "hands over a string that is not JSON as the string itself", %{request_id: request_id} do
      assert :ok == _receive_result(request_id, "ok")
      assert_receive {:response, ^request_id, "ok"}
      assert :ok == _await_acknowledged(request_id)
    end

    test "hands over a result sent as a bare number", %{request_id: request_id} do
      assert :ok == _receive_result(request_id, 42)
      assert_receive {:response, ^request_id, 42}
      assert :ok == _await_acknowledged(request_id)
    end

    test "hands over a missing result as nil", %{request_id: request_id} do
      msg = %{"type" => "sendActionResult", "id" => request_id}

      assert :ok == ActionInvoker.handle_message(:"action-ws", msg, %InvokerState{})
      assert_receive {:response, ^request_id, nil}
      assert :ok == _await_acknowledged(request_id)
    end
  end

  # The ack reaches the mock over the socket, after `handle_message/3` has already returned.
  defp _await_acknowledged(request_id, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      Mock.acknowledged?(request_id) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :not_acknowledged

      true ->
        Process.sleep(10)
        _await_acknowledged(request_id, deadline)
    end
  end

  defp _receive_result(request_id, result) do
    msg = %{"type" => "sendActionResult", "id" => request_id, "result" => result}
    ActionInvoker.handle_message(:"action-ws", msg, %InvokerState{})
  end
end
