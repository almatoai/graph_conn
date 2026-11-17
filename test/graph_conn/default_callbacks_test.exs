defmodule GraphConn.DefaultCallbacksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias GraphConn.ActionApi.Invoker.State, as: InvokerState
  alias GraphConn.{Mock, TestClient}
  alias GraphConn.Test.IsolatedInvoker

  defmodule Plain do
    @moduledoc "A client that keeps every default callback."
    use GraphConn, otp_app: :graph_conn
  end

  # The default callbacks only log at debug, so that is the level they can fail at.
  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  test "the default main-connection callback takes a tuple status" do
    assert :ok == Plain.on_status_change({:disconnected, :started}, %{})
  end

  test "the default WebSocket callback takes a tuple status" do
    status = {:shutdown, "server sent close request: bye"}
    assert :ok == Plain.on_status_change(:"action-ws", status, %{})
  end

  test "the action invoker's main-connection callback survives a {:disconnected, _} transition" do
    TestClient.put_env(:retry_initial_ms, 20)
    on_exit(fn -> Mock.clear_rate_limit(:versions_omission) end)
    # One discovery asks both the main and the auth url, so this strips `auth` from one discovery.
    Mock.omit_versions_api("auth", 2)

    _trace_tuple_status_calls()

    start_and_await_ready = fn ->
      start_supervised!({IsolatedInvoker, IsolatedInvoker.config()})
      _await_invoker_ready(System.monotonic_time(:millisecond) + 6_000)
    end

    {:ok, log} = with_log(start_and_await_ready)

    assert log =~ "Graph API versions name no auth api, looking them up again"

    # No pending fetch and not `:ready`, so the call can only have matched the catch-all clause.
    assert_receive {:trace, caller, :call,
                    {IsolatedInvoker, :on_status_change,
                     [
                       {:disconnected, _reason},
                       %InvokerState{status: :initialized, fetch_retry: nil}
                     ]}}

    assert_receive {:trace, ^caller, :return_from, {IsolatedInvoker, :on_status_change, 2}, :ok}
  end

  defp _trace_tuple_status_calls do
    Code.ensure_loaded!(IsolatedInvoker)
    mfa = {IsolatedInvoker, :on_status_change, 2}
    match_spec = [{[{:disconnected, :_}, :_], [], [{:return_trace}]}]
    1 = :erlang.trace_pattern(mfa, match_spec, [:global])
    _traced = :erlang.trace(:all, true, [:call, {:tracer, self()}])

    untrace = fn ->
      _untraced = :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern(mfa, false, [:global])
    end

    on_exit(untrace)
  end

  defp _await_invoker_ready(deadline) do
    IsolatedInvoker
    |> GraphConn.get_client_state()
    |> case do
      %InvokerState{status: :ready} ->
        :ok

      state ->
        assert System.monotonic_time(:millisecond) < deadline,
               "IsolatedInvoker never became ready, last: #{inspect(state)}"

        Process.sleep(20)
        _await_invoker_ready(deadline)
    end
  end
end
