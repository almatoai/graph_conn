defmodule GraphConn.ActionApi.InvokerFetchRetryTest do
  @moduledoc """
  What an invoker does when fetching its capabilities or applicabilities fails.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias GraphConn.ActionApi.Invoker.State, as: InvokerState
  alias GraphConn.{ClientState, Mock, TestClient}
  alias GraphConn.Test.IsolatedInvoker

  @token "action_isolated"
  @receive_timeout_ms 500
  # Past the first retry's longest wait on the default backoff curve.
  @ready_deadline_ms 6_000
  # Finch's default pool checkout timeout, which GraphRestCalls leaves in place.
  @pool_checkout_timeout_ms 5_000
  # Past a checkout timing out, with room for a loaded host.
  @checkout_raised_deadline_ms @pool_checkout_timeout_ms * 2

  setup do
    disarm = fn ->
      Mock.clear_rate_limit({:action_fetch, @token, "capabilities"})
      Mock.clear_rate_limit({:action_fetch, @token, "applicabilities"})
    end

    on_exit(disarm)
  end

  describe "a failed fetch at start-up" do
    test "retries a capabilities fetch answered 500 with an empty body until it is ready" do
      Mock.fail_action_fetch(@token, "capabilities", 1, {:status, 500, ""})

      {_result, log} = with_log(&_start_and_assert_recovers/0)

      assert [warning] = _fetch_warnings(log)
      assert warning =~ "capabilities"
      assert warning =~ "500"
    end

    test "retries an applicabilities fetch that timed out until it is ready" do
      Mock.fail_action_fetch(@token, "applicabilities", 1, {:hang, @receive_timeout_ms * 3})

      {_result, log} =
        with_log(fn -> _start_and_assert_recovers(timeout: @receive_timeout_ms) end)

      assert [warning] = _fetch_warnings(log)
      assert warning =~ "applicabilities"
      assert warning =~ "timeout"
    end

    test "waits out the retry-after a 429 on the capabilities fetch advertises before fetching again" do
      # Past the longest first retry on the default backoff curve, so only the advertised wait
      # can hold the fetch back this long.
      retry_after_seconds = 3
      Mock.fail_action_fetch(@token, "capabilities", 1, {:rate_limited, retry_after_seconds})

      started_and_ready = fn ->
        _start_invoker()
        _await_ready(@ready_deadline_ms + retry_after_seconds * 1_000)
      end

      {elapsed, :ok} = TestClient.measure(started_and_ready)

      assert elapsed >= retry_after_seconds * 1_000
    end

    test "survives a 401 on the first capabilities fetch and becomes ready" do
      Mock.fail_action_fetch(@token, "capabilities", 1, {:status, 401, ""})
      _start_invoker()
      manager_ref = _monitor_connection_manager()

      assert :ok == _await_ready()
      refute_received {:DOWN, ^manager_ref, :process, _manager, _reason}
    end
  end

  describe "a fetch attempt that raises" do
    setup do
      Mock.fail_action_fetch(@token, "capabilities", 1, {:status, 500, ""})
      _start_invoker()
      %{retry: _await_pending_retry()}
    end

    test "is retried, and the invoker still becomes ready", %{retry: retry} do
      # A suspended pool makes the next request's checkout time out, which Finch raises.
      pools = _rest_pools()
      Enum.each(pools, &:sys.suspend/1)
      on_exit(fn -> Enum.each(pools, &_resume/1) end)

      :ok = _await_stacktrace(retry, &_in_pool_checkout?/1)
      checkout_raised_by = System.monotonic_time(:millisecond) + @checkout_raised_deadline_ms
      :ok = _await_stacktrace(retry, &(not _in_pool_checkout?(&1)), checkout_raised_by)
      Enum.each(pools, &:sys.resume/1)

      assert :ok == _await_ready(@ready_deadline_ms * 2)
    end
  end

  describe "a fetch process whose caller dies before handing it the fetch" do
    setup do
      _start_invoker()
      :ok = _await_ready()
    end

    test "stops with its caller" do
      client_state =
        IsolatedInvoker
        |> Module.concat("ClientState")
        |> Process.whereis()

      :sys.suspend(client_state)
      on_exit(fn -> _resume(client_state) end)

      initialized = %InvokerState{status: :initialized}
      caller = spawn(fn -> IsolatedInvoker.on_status_change(:ready, initialized) end)
      fetcher = _await_parked_fetcher()
      fetcher_ref = Process.monitor(fetcher)

      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^fetcher_ref, :process, ^fetcher, :normal}
    end
  end

  describe "a status change while a retry is pending" do
    setup do
      Mock.fail_action_fetch(@token, "capabilities", 1, {:status, 500, ""})
      _start_invoker()
      %{retry: _await_pending_retry()}
    end

    test "a second :ready neither fetches again nor replaces the pending retry", %{retry: retry} do
      _change_status(:ready)

      assert %InvokerState{status: :initialized, fetch_retry: ^retry} =
               GraphConn.get_client_state(IsolatedInvoker)

      retry_ref = Process.monitor(retry)
      assert :ok == _await_ready()
      assert_receive {:DOWN, ^retry_ref, :process, ^retry, :normal}, @ready_deadline_ms
    end

    test "leaving :ready cancels the pending retry before it fetches again", %{retry: retry} do
      retry_ref = Process.monitor(retry)
      Mock.fail_action_fetch(@token, "capabilities", 1, {:status, 500, ""})

      _change_status({:disconnected, :closed})

      # Well under the shortest backoff, so only a cancelled retry can be gone by now.
      assert_receive {:DOWN, ^retry_ref, :process, ^retry, :normal}, 500
      assert {:ok, {:status, 500, ""}} == Mock.take_action_fetch_failure(@token, "capabilities")
      assert %InvokerState{status: :initialized, fetch_retry: nil} = _await_fetch_retry_cleared()
    end

    test "the next :ready after a cancel fetches again and becomes ready" do
      manager_ref = _monitor_connection_manager()

      _change_status({:disconnected, :closed})
      _await_fetch_retry_cleared()
      _change_status(:ready)

      assert :ok == _await_ready()
      refute_received {:DOWN, ^manager_ref, :process, _manager, _reason}
    end

    test "a pending fetch that dies leaves the connection manager up, and the next :ready recovers",
         %{retry: retry} do
      retry_ref = Process.monitor(retry)
      manager_ref = _monitor_connection_manager()

      Process.exit(retry, :kill)

      assert_receive {:DOWN, ^retry_ref, :process, ^retry, :killed}
      _change_status(:ready)

      assert :ok == _await_ready()
      refute_received {:DOWN, ^manager_ref, :process, _manager, _reason}
    end

    test "a retry that is no longer the pending one does not make the invoker ready",
         %{retry: retry} do
      retry_ref = Process.monitor(retry)

      IsolatedInvoker
      |> GraphConn.get_client_state()
      |> Map.put(:fetch_retry, nil)
      |> then(&GraphConn.put_client_state(IsolatedInvoker, &1))

      assert_receive {:DOWN, ^retry_ref, :process, ^retry, :normal}, @ready_deadline_ms
      assert %InvokerState{status: :initialized} = GraphConn.get_client_state(IsolatedInvoker)
    end
  end

  describe "reconfigure/0" do
    setup do
      _start_invoker()
      :ok = _await_ready()
    end

    test "keeps the capabilities it had when the fetch fails" do
      capabilities = IsolatedInvoker.available_capabilities()
      Mock.fail_action_fetch(@token, "capabilities", 1, {:status, 500, ""})

      assert {:error, _reason} = IsolatedInvoker.reconfigure()
      assert capabilities == IsolatedInvoker.available_capabilities()
    end

    test "returns the advertised wait when the capabilities fetch is answered 429" do
      Mock.fail_action_fetch(@token, "capabilities", 1, {:rate_limited, 2})
      assert {:error, {"capabilities", {:rate_limited, 2_000}}} == IsolatedInvoker.reconfigure()
    end

    test "a state update that raises fails only its caller, leaving the client up" do
      manager_ref = _monitor_connection_manager()
      before = GraphConn.get_client_state(IsolatedInvoker)
      boom = fn _state -> raise "boom" end

      assert_raise RuntimeError, fn -> ClientState.update_state(IsolatedInvoker, boom) end
      assert before == GraphConn.get_client_state(IsolatedInvoker)
      refute_received {:DOWN, ^manager_ref, :process, _manager, _reason}
    end

    test "survives a 401 when a configChanged message makes it reconfigure" do
      Process.register(self(), IsolatedInvoker.Observer)
      :ok = _await_isolated_socket()
      manager_ref = _monitor_connection_manager()
      Mock.fail_action_fetch(@token, "capabilities", 1, {:status, 401, ""})
      config_changed = Jason.encode!(%{type: "configChanged"})

      Registry.TestSockets
      |> Registry.dispatch({:client, "isolated"}, fn entries ->
        for {socket, _registration} <- entries, do: send(socket, config_changed)
      end)

      assert_receive {:reconfigured, :ok}
      assert :error == Mock.take_action_fetch_failure(@token, "capabilities")
      refute_received {:DOWN, ^manager_ref, :process, _manager, _reason}
    end
  end

  defp _start_invoker(opts \\ []) do
    config = IsolatedInvoker.config(opts)
    start_supervised!({IsolatedInvoker, config})
  end

  defp _change_status(status) do
    state = GraphConn.get_client_state(IsolatedInvoker)
    IsolatedInvoker.on_status_change(status, state)
  end

  defp _start_and_assert_recovers(opts \\ []) do
    _start_invoker(opts)
    _await_pending_retry()
    manager_ref = _monitor_connection_manager()

    assert :ok == _await_ready()
    assert %{"ExecuteCommand" => _} = IsolatedInvoker.available_capabilities()
    refute_received {:DOWN, ^manager_ref, :process, _manager, _reason}
  end

  defp _await_fetch_retry_cleared,
    do: _await_state(&match?(%InvokerState{fetch_retry: nil}, &1))

  defp _await_isolated_socket(
         deadline \\ System.monotonic_time(:millisecond) + @ready_deadline_ms
       ) do
    Registry.TestSockets
    |> Registry.lookup({:client, "isolated"})
    |> case do
      [_socket | _others] ->
        :ok

      [] ->
        assert System.monotonic_time(:millisecond) < deadline,
               "the invoker never opened action-ws"

        Process.sleep(20)
        _await_isolated_socket(deadline)
    end
  end

  defp _fetch_warnings(log) do
    log
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ "[warning]" and &1 =~ inspect(IsolatedInvoker)))
  end

  defp _monitor_connection_manager do
    IsolatedInvoker
    |> Module.concat(ConnectionManager)
    |> Process.whereis()
    |> Process.monitor()
  end

  defp _await_pending_retry do
    %InvokerState{fetch_retry: retry} =
      _await_state(&match?(%InvokerState{fetch_retry: retry} when is_pid(retry), &1))

    retry
  end

  defp _await_ready(timeout_ms \\ @ready_deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    ready? = &match?(%InvokerState{status: :ready}, &1)
    %InvokerState{status: :ready} = _await_state(ready?, deadline)
    :ok
  end

  defp _rest_pools do
    finch = GraphConn.Supervisor.finch_name(IsolatedInvoker)
    pools = Registry.select(finch, [{{:_, :"$1", :_}, [], [:"$1"]}])
    assert [_pool | _others] = pools
    pools
  end

  defp _resume(pid) do
    :sys.resume(pid)
  catch
    :exit, _not_suspended_or_gone -> :ok
  end

  defp _in_pool_checkout?(stacktrace),
    do: Enum.any?(stacktrace, &match?({NimblePool, _function, _arity, _location}, &1))

  defp _await_stacktrace(
         pid,
         matches?,
         deadline \\ System.monotonic_time(:millisecond) + @ready_deadline_ms
       ) do
    stacktrace =
      pid
      |> Process.info(:current_stacktrace)
      |> case do
        {:current_stacktrace, stacktrace} -> stacktrace
        nil -> []
      end

    cond do
      matches?.(stacktrace) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(20)
        _await_stacktrace(pid, matches?, deadline)

      true ->
        message =
          "#{inspect(pid)} never reached the awaited stacktrace, last: #{inspect(stacktrace)}"

        flunk(message)
    end
  end

  defp _await_parked_fetcher(deadline \\ System.monotonic_time(:millisecond) + @ready_deadline_ms) do
    Process.list()
    |> Enum.filter(&_parked_fetcher?/1)
    |> case do
      [fetcher] ->
        fetcher

      [] ->
        assert System.monotonic_time(:millisecond) < deadline, "no fetcher was started"
        Process.sleep(20)
        _await_parked_fetcher(deadline)

      fetchers ->
        flunk("expected one parked fetcher, found: #{inspect(fetchers)}")
    end
  end

  defp _parked_fetcher?(pid) do
    pid
    |> Process.info(:current_stacktrace)
    |> case do
      {:current_stacktrace, [{IsolatedInvoker, function, _arity, _location} | _frames]} ->
        function
        |> Atom.to_string()
        |> String.contains?("_start_fetcher")

      _other ->
        false
    end
  end

  defp _await_state(
         matches?,
         deadline \\ System.monotonic_time(:millisecond) + @ready_deadline_ms
       ) do
    state = GraphConn.get_client_state(IsolatedInvoker)

    cond do
      matches?.(state) ->
        state

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(20)
        _await_state(matches?, deadline)

      true ->
        flunk("IsolatedInvoker never reached the awaited state, last: #{inspect(state)}")
    end
  end
end
