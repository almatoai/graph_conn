defmodule GraphConn.ActionApi.InvokerRateLimitedTest do
  @moduledoc """
  What an invoker does when the gateway denies a request on the open socket.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias GraphConn.ActionApi.Invoker.RequestRegistry
  alias GraphConn.ActionApi.Invoker.State, as: InvokerState
  alias GraphConn.{Mock, TestClient}

  @retry_after_ms 1_986

  setup do
    on_exit(fn -> Mock.clear_rate_limit({:request_deny, "standalone"}) end)
    :ok
  end

  test "logs a denial the caller acts on as before" do
    Mock.deny_next_request("standalone", 1, @retry_after_ms)

    executed = fn ->
      ActionInvoker.execute("ExecuteCommand", %{"command" => "ls", "host" => "localhost"})
    end

    {_result, log} = with_log(executed)

    assert log =~ "[ActionInvoker] Rate limited, retry in #{@retry_after_ms}ms"
  end

  test "takes a denial from a node still on the old message shape" do
    Mock.ignore_next_request("standalone", 1)
    caller = self()

    # What a node before 1.12.0 sends a caller whose request was denied.
    old_node = fn ->
      request_id = _await_registered(caller)
      send(caller, {:rate_limited, request_id, @retry_after_ms})
    end

    spawn_link(old_node)

    measured = fn ->
      ActionInvoker.execute("ExecuteCommand", %{"command" => "ls", "host" => "localhost"})
    end

    {elapsed, result} = TestClient.measure(measured)

    assert {:error, _request_id, {:rate_limited, @retry_after_ms}} = result
    assert elapsed < 3_000
  end

  test "names a denial for a request no caller is waiting on" do
    request_id = UUID.uuid4()
    denial = %{"error" => %{"code" => 429, "retryAfterMs" => @retry_after_ms}, "id" => request_id}

    logged = fn -> ActionInvoker.handle_message(:"action-ws", denial, %InvokerState{}) end
    {_returned, log} = with_log(logged)

    assert log =~ "[warning]"
    assert log =~ "no waiting caller"
    assert log =~ request_id
    assert log =~ "rate_limited"
  end

  test "answers the caller with the advertised wait instead of resending the request" do
    Mock.deny_next_request("standalone", 1, @retry_after_ms)

    measured = fn ->
      ActionInvoker.execute("ExecuteCommand", %{"command" => "ls", "host" => "localhost"})
    end

    {elapsed, result} = TestClient.measure(measured)

    assert {:error, request_id, {:rate_limited, @retry_after_ms}} = result
    assert is_binary(request_id)

    # Resending would cost three more sends and about nine seconds, into a gateway that has just
    # asked for a wait.
    assert elapsed < 3_000
  end

  test "leaves no registry entry behind after a denied request" do
    Mock.deny_next_request("standalone", 1, @retry_after_ms)

    assert {:error, request_id, {:rate_limited, _ms}} =
             ActionInvoker.execute("ExecuteCommand", %{"command" => "ls", "host" => "localhost"})

    registered =
      ActionInvoker
      |> RequestRegistry.name()
      |> Registry.lookup(request_id)

    assert [] == registered
  end

  test "names a denial that carries no request id rather than reporting it as unexpected" do
    denial = %{
      "error" => %{
        "code" => 429,
        "message" => "Rate limit exceeded",
        "retryAfterMs" => @retry_after_ms
      }
    }

    logged = fn -> ActionInvoker.handle_message(:"action-ws", denial, %InvokerState{}) end
    {_returned, log} = with_log(logged)

    assert log =~ "Rate limited with no request id"
    assert log =~ "[warning]"
    refute log =~ "Received unexpected message from action-ws"
  end

  test "names a denial whose request id is null rather than dropping it silently" do
    # A present-but-null id belongs to no caller either, so it wants the same line an absent one
    # gets. `Map.get/3` and a `"id" => request_id` pattern both read a null key as present.
    denial = %{"error" => %{"code" => 429, "retryAfterMs" => @retry_after_ms}, "id" => nil}
    logged = fn -> ActionInvoker.handle_message(:"action-ws", denial, %InvokerState{}) end

    {_returned, log} = with_log(logged)

    assert log =~ "Rate limited with no request id"
  end

  test "hands the caller a wait it can act on when the gateway advertises a malformed one" do
    # `{:rate_limited, retry_after_ms}` is documented as a non-negative integer of milliseconds,
    # and a consumer sleeps on it or arms a timer with it, so every shape a frame can carry has
    # to land on one.
    reached =
      for advertised <- [nil, "1986", -1, 999_999_999_999] do
        request_id = UUID.uuid4()
        :ok = RequestRegistry.register(ActionInvoker, request_id)

        denial = %{"error" => %{"code" => 429, "retryAfterMs" => advertised}, "id" => request_id}
        ActionInvoker.handle_message(:"action-ws", denial, %InvokerState{})

        assert_receive {:refused, ^request_id, {:rate_limited, retry_after_ms}}
        RequestRegistry.unregister(ActionInvoker, request_id)

        {advertised, retry_after_ms}
      end

    unusable =
      reached
      |> Enum.reject(fn {_advertised, got} ->
        is_integer(got) and got >= 0 and got <= 86_400_000
      end)

    assert [] == unusable, "reached the caller unusable: #{inspect(unusable)}"
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
end
