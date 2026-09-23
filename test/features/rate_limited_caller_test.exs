defmodule GraphConn.Features.RateLimitedCallerTest do
  @moduledoc """
  Feature: Telling the caller a request was rate limited

    As a caller of an action invoker
    I want a send that cannot go out to come back as an error naming my request
    So that I can decide what to do about it, rather than dying on a match I never made.

  Background:
    Given a running action invoker with a live action-ws connection
    And a Graph that can refuse the next WebSocket upgrade with a 429
  """

  use ExUnit.Case, async: false

  @moduletag :feature

  alias GraphConn.Mock

  setup do
    on_exit(fn ->
      Mock.clear_rate_limit({:ws_upgrade, "standalone"})
      _await_ws_connection(System.monotonic_time(:millisecond) + 15_000)
    end)

    :ok
  end

  describe "Scenario: sending a request while the WebSocket reopen is rate limited" do
    test "answers the caller with an error naming the request, instead of raising" do
      # Given the invoker's connection has gone, and the graph refuses to let it back in
      _refuse_next_reopen(429, 2)

      # When a caller sends a request
      result =
        ActionInvoker.execute("ExecuteCommand", %{"command" => "ls", "host" => "localhost"})

      # Then it is told which request failed and why. The request id is the load-bearing part:
      # without it a consumer cannot tell which of its in-flight calls was refused, and engine
      # drops the reply into its "unknown" bucket.
      assert {:error, request_id, {:rate_limited, retry_after_ms}} = result
      assert is_binary(request_id)

      # The wait has to carry the advertised two seconds. Returning a constant 0 here would tell
      # every consumer "retry now" while the window is still open, and every other assertion in
      # the suite wildcards this value.
      assert retry_after_ms > 1_000
    end
  end

  describe "Scenario: sending a request the connection cannot carry at all" do
    test "answers the caller with an error naming the request, rather than raising" do
      # Not a rate limit, so it must not be reported as one -- but it still has to reach the
      # caller as an answer. Without a catch-all on the send it is a CaseClauseError in the
      # calling process, which is the same class of failure the 429 path was fixed for.
      _forget_action_ws_version()

      result =
        ActionInvoker.execute("ExecuteCommand", %{"command" => "ls", "host" => "localhost"})

      # `:not_sent`, not `:nack`: the Graph never saw this request, so reporting it as a
      # rejection would tell a consumer -- and then the KI -- that the Graph refused something it
      # never received.
      assert {:error, request_id, {:not_sent, {:unknown_api, _apis}}} = result
      assert is_binary(request_id)
    end
  end

  # Drops action-ws from the invoker's cached versions, so its next send cannot be routed at all.
  defp _forget_action_ws_version do
    [{:versions, versions}] = :ets.lookup(ActionInvoker, :versions)
    on_exit(fn -> :ets.insert(ActionInvoker, {:versions, versions}) end)

    :ets.insert(ActionInvoker, {:versions, Map.delete(versions, :"action-ws")})
  end

  defp _refuse_next_reopen(status, retry_after_seconds) do
    conn_pid = _conn_pid()
    assert is_pid(conn_pid)

    Mock.reject_ws_upgrade("standalone", 1, status, retry_after_seconds)
    Process.exit(conn_pid, :kill)
    _await_pending_reopen(System.monotonic_time(:millisecond) + 5_000)
  end

  defp _await_pending_reopen(deadline) do
    ActionInvoker
    |> :ets.lookup({:"action-ws", :reopen_at})
    |> case do
      [{_key, reopen_at}] when is_integer(reopen_at) ->
        :ok

      _not_pending_yet ->
        assert System.monotonic_time(:millisecond) < deadline, "no reopen was marked pending"
        Process.sleep(10)
        _await_pending_reopen(deadline)
    end
  end

  defp _conn_pid do
    ActionInvoker
    |> :ets.lookup({:"action-ws", :conn_pid})
    |> case do
      [{_key, conn_pid}] -> conn_pid
      [] -> nil
    end
  end

  # The invoker is shared with the rest of the suite, so its connection has to be back before
  # this test hands over.
  defp _await_ws_connection(deadline) do
    cond do
      is_pid(_conn_pid()) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(50)
        _await_ws_connection(deadline)

      true ->
        flunk("ActionInvoker never got its action-ws connection back")
    end
  end
end
