defmodule GraphConn.ActionApi.HandlerCrashTest do
  use ExUnit.Case, async: false

  for {kind, params} <- [
        raise: %{"raise" => "capability blew up"},
        exit: %{"exit" => "capability exited"},
        throw: %{"throw" => "capability threw"}
      ] do
    @params params

    test "an execute that ends in #{kind} reaches the invoker as an action_status 54 error" do
      assert {:error, req_id,
              %{"req_id" => req_id, "action_status" => 54, "action_error" => error}} =
               _execute(@params)

      assert error =~ "capability"
      refute error =~ ".ex:"
    end
  end

  test "an execute killed by a crashing linked helper reaches the invoker as an action_status 54 error" do
    assert {:error, req_id, %{"req_id" => req_id, "action_status" => 54, "action_error" => error}} =
             _execute(%{"crash_linked" => "helper blew up"})

    assert error =~ "helper blew up"
    refute error =~ ".ex:"
  end

  test "an execute that outlives its execution timeout reaches the invoker as an action_status 13 error" do
    # In seconds, as the invoker takes it.
    params = %{"command" => "sleep", "hang" => true, "timeout" => 1}

    assert {:error, req_id, %{"req_id" => req_id, "action_status" => 13, "action_error" => error}} =
             ActionInvoker.execute(UUID.uuid4(), _ah_id(), "RunScript", params)

    assert error =~ "1000ms"

    assert {:ok, cached} = Cachex.get(TestActionHandler._request_cache_name(), req_id)
    assert %{"error" => %{"action_status" => 13}} = Jason.decode!(cached)
  end

  test "a crashed execute is cached as its error, so a redelivery never waits on it" do
    {:error, req_id, _error} = _execute(%{"raise" => "capability blew up"})

    assert {:ok, cached} = Cachex.get(TestActionHandler._request_cache_name(), req_id)
    assert %{"error" => %{"action_status" => 54}} = Jason.decode!(cached)
  end

  defp _execute(params) do
    params = Map.merge(%{"command" => "ls"}, params)
    ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params)
  end

  defp _ah_id do
    ActionInvoker.available_applicabilities()
    |> Map.keys()
    |> hd()
  end
end
