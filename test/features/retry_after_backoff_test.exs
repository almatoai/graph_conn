defmodule GraphConn.Features.RetryAfterBackoffTest do
  @moduledoc """
  Feature: Retry-after-aware backoff

    As a client of a rate-limited Graph
    I want a denied request to be retried only once the advertised window has passed
    So that the client stops re-denying itself on a schedule of its own invention.

  Background:
    Given a Graph whose authentication, version and WebSocket-upgrade endpoints can each deny a
    client with a 429
    And no client running yet
  """

  use ExUnit.Case, async: false

  @moduletag :feature

  alias GraphConn.{Mock, Request, TestClient, TestConn}

  setup do
    TestClient.stop()

    on_exit(fn ->
      Mock.clear_rate_limit("action_invoker")
      Mock.clear_rate_limit(:versions)
      Mock.clear_rate_limit({:ws_upgrade, "invoker"})
      TestClient.stop()
    end)

    :ok
  end

  describe "Scenario: authenticating against a Graph that is rate limiting" do
    test "waits out the advertised retry-after before authenticating again" do
      # A curve capped far below the advertised wait, so nothing but honouring that wait can
      # explain a delay past two seconds. Measured with the default curve instead, and the
      # advertised wait ignored, the same run lands at 1.1s-1.8s.
      TestClient.put_env(:retry_initial_ms, 100)
      TestClient.put_env(:retry_max_ms, 200)

      # Given the Graph denies the client's first authentication, asking for two seconds
      Mock.rate_limit_auth("action_invoker", 1, 2)

      # When the client is started
      {elapsed, _ready} =
        TestClient.measure(fn ->
          assert {:ok, _sup_pid} = TestClient.start()
          assert_receive {:conn_status_changed, :ready}, 15_000
        end)

      # Then it held off until the window the server named had passed, which with a 200ms cap
      # also means the advertised wait beat the cap.
      #
      # Deliberately one-sided. Contention only ever makes `elapsed` larger, so a lower bound
      # cannot fail for reasons unrelated to the code, whereas an upper bound is the one thing
      # here a busy machine could break. An over-wait is still caught -- by the `assert_receive`
      # above -- and the curve and its cap are pinned arithmetically, immune to load, in
      # `GraphConn.ConnectionManagerTest`.
      assert elapsed >= 2_000
    end
  end

  describe "Scenario: discovering API versions against a Graph that is rate limiting" do
    test "waits out the advertised retry-after before asking for versions again" do
      # Same small cap as the scenario above, so only the advertised wait can explain 2s.
      TestClient.put_env(:retry_initial_ms, 100)
      TestClient.put_env(:retry_max_ms, 200)

      # Given the Graph denies the client's first version lookup, asking for two seconds
      Mock.rate_limit_versions(1, 2)

      # When the client is started
      {elapsed, _ready} =
        TestClient.measure(fn ->
          assert {:ok, _sup_pid} = TestClient.start()
          assert_receive {:conn_status_changed, :ready}, 15_000
        end)

      # Then it held off until that window had passed, rather than retrying on the flat one
      # second this path used to use regardless of what the server asked for. One-sided for the
      # same reason as the scenario above.
      assert elapsed >= 2_000
    end
  end

  describe "Scenario: a rate-limited WebSocket upgrade" do
    test "backs the caller off instead of taking the connection manager down with it" do
      TestClient.put_env(:retry_initial_ms, 100)
      TestClient.put_env(:retry_max_ms, 200)

      assert {:ok, _sup_pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000
      manager = _manager_pid()
      assert is_pid(manager)

      # Given the Graph answers the next upgrade with a 429 asking for two seconds
      Mock.reject_ws_upgrade("invoker", 1, 429, 2)

      # When a caller needs the action-ws connection
      result = TestConn.execute(:"action-ws", %Request{path: "capabilities"})

      # Then it is told to back off, rather than being parked on the 5ms spin for the whole
      # window or losing its reply to a crash.
      assert {:error, {:rate_limited, retry_after_ms}} = result

      # And the wait it is handed is the advertised two seconds, not the 200ms cap. That is what
      # proves the hint survived the trip through the upgrade: a hard match there raises a
      # MatchError the manager's catch-all absorbs, which looks identical except the advertised
      # wait is gone. A duration shrinks as time passes, so this cannot be bounded from below the
      # way a stamp could -- the margin does that job instead: 5x above the 200ms cap and ~1s
      # below the 2_000ms floor.
      assert retry_after_ms > 1_000

      # And the manager is the process it was before. This is the regression that matters: the
      # upgrade used to MatchError in init/1, which became a CaseClauseError here, which took
      # the whole :one_for_all subtree -- ClientState, the WS connections and the Finch pool --
      # down and re-authenticated, all from one 429.
      assert manager == _manager_pid()
      assert Process.alive?(manager)
      assert :ready == TestConn.status()
    end
  end

  # Built from a string so an alias on `ConnectionManager` could never expand this into a name
  # that resolves to nil -- which would make the comparison above pass on `nil == nil`.
  defp _manager_pid do
    TestConn
    |> Module.concat("ConnectionManager")
    |> Process.whereis()
  end
end
