defmodule GraphConn.ActionApi.FrameLimitTest do
  use ExUnit.Case, async: false

  alias GraphConn.ActionApi.Responder
  alias GraphConn.Request

  # What the mock's `hello` advertises to the "handler" client, set in config/test.exs.
  @handler_limit 200_000

  describe "an oversized result" do
    test "reaches the invoker as an action_status 59 error" do
      assert {:error, req_id,
              %{
                "req_id" => req_id,
                "action_status" => 59,
                "action_error" => "Response was too big" <> _size
              }} = _execute_oversized()
    end

    test "is cached as the error, so a redelivery never carries it" do
      {:error, req_id, _error} = _execute_oversized()

      assert {:ok, cached} = Cachex.get(TestActionHandler._request_cache_name(), req_id)
      assert %{"error" => %{"action_status" => 59}} = Jason.decode!(cached)
    end
  end

  describe "the responder" do
    test "never pushes an oversized result" do
      req_id = _listen_for_result()

      req_id
      |> _oversized_result_request()
      |> Responder.return_response(TestActionHandler, 3_000)

      assert %{"error" => %{"action_status" => 59}} = _received_result()
    end

    test "never resends an oversized result" do
      req_id = _listen_for_result()

      TestActionHandler
      |> Responder.name()
      |> GenServer.cast({:register_response, _oversized_result_request(req_id), 50})

      assert %{"error" => %{"action_status" => 59}} = _received_result()
    end
  end

  defp _execute_oversized do
    params = %{
      "other_handler" => "Echo",
      "command" => "ls",
      "payload" => String.duplicate("a", @handler_limit)
    }

    ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params)
  end

  defp _oversized_result_request(req_id) do
    result = Jason.encode!(%{data: String.duplicate("a", @handler_limit)})
    %Request{body: %{id: req_id, type: "sendActionResult", result: result}}
  end

  # The mock forwards every result it receives to whoever registered under its request id.

  # The mock forwards every result it receives to whoever registered under its request id.
  defp _listen_for_result do
    req_id = UUID.uuid4()
    {:ok, _owner} = Registry.register(Registry.TestSockets, req_id, {})
    req_id
  end

  defp _received_result do
    assert_receive frame when is_binary(frame)
    %{"type" => "sendActionResult", "result" => result} = Jason.decode!(frame)
    Jason.decode!(result)
  end

  defp _ah_id do
    ActionInvoker.available_applicabilities()
    |> Map.keys()
    |> hd()
  end
end
