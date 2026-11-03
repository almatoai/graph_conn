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
             _execute_new("RunScript", params)

    assert error =~ "1000ms"

    assert {:ok, cached} = _cached(req_id)
    assert %{"error" => %{"action_status" => 13}} = Jason.decode!(cached)
  end

  test "a result that is not valid UTF-8 reaches the invoker as a bounded action_status 54 error" do
    params = %{"invalid_utf8" => String.duplicate("a", 300_000)}

    assert {:error, req_id, %{"req_id" => req_id, "action_status" => 54, "action_error" => error}} =
             _execute(params)

    assert error =~ "Jason.EncodeError"
    assert error =~ "invalid byte 0xFF"
    assert byte_size(error) < 5_000

    assert {:ok, cached} = _cached(req_id)
    assert %{"error" => %{"action_status" => 54}} = Jason.decode!(cached)
  end

  test "a crashed execute is cached as its error, so a redelivery never waits on it" do
    {:error, req_id, _error} = _execute(%{"raise" => "capability blew up"})

    assert {:ok, cached} = _cached(req_id)
    assert %{"error" => %{"action_status" => 54}} = Jason.decode!(cached)
  end

  defp _execute(params) do
    params = Map.merge(%{"command" => "ls"}, params)
    _execute_new("ExecuteCommand", params)
  end

  defp _execute_new(capability, params, opts \\ []) do
    req_id = UUID.uuid4()
    _execute(req_id, capability, params, opts)
  end

  defp _execute(req_id, capability, params, opts) do
    ah_id = _ah_id()
    ActionInvoker.execute(req_id, ah_id, capability, params, opts)
  end

  defp _cached(req_id) do
    TestActionHandler._request_cache_name()
    |> Cachex.get(req_id)
  end

  defp _ah_id do
    ActionInvoker.available_applicabilities()
    |> Map.keys()
    |> hd()
  end
end
