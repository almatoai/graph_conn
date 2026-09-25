defmodule GraphConn.ConnectionManagerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias GraphConn.{ConnectionManager, Mock, Request, TestClient, TestConn}

  describe "execute/4 with no connection running" do
    setup do
      TestClient.stop()
      on_exit(&TestClient.stop/0)
      :ok
    end

    test "gives up on a client that isn't coming instead of blocking forever" do
      _put_startup_wait(200)

      {elapsed, result} = TestClient.measure(fn -> TestConn.execute(:action, _request()) end)

      assert {:error, :not_started} = result

      # It waited out the grace period rather than failing on the first look, and it did stop
      # waiting -- which is the whole point: this call used to never return at all.
      assert elapsed >= 200
    end

    test "keeps waiting while still inside the grace period" do
      _put_startup_wait(1_000)

      task = Task.async(fn -> TestConn.execute(:action, _request()) end)

      # Nothing has been decided yet a third of the way in, so a client that is merely slow to
      # start still has time to turn up.
      assert nil == Task.yield(task, 300)

      assert {:error, :not_started} = Task.await(task, 2_000)
    end

    test "fails on the first look when the grace period is disabled" do
      _put_startup_wait(0)

      {elapsed, result} = TestClient.measure(fn -> TestConn.execute(:action, _request()) end)

      assert {:error, :not_started} = result
      assert elapsed < 100
    end

    test "picks up a connection that starts during the grace period" do
      _put_startup_wait(2_000)

      task = Task.async(fn -> TestConn.execute(:action, _request()) end)

      # Let the caller land in the wait, then bring the client up underneath it. This is the race
      # the wait exists for: `ConnectionManager` creates the table in `init/1` and
      # `GraphConn.Supervisor` starts that child last, so a caller can arrive first.
      Process.sleep(50)
      assert {:ok, _pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}

      # The call rode out the race instead of giving up on a client that was on its way. What the
      # graph answers once it gets there is `execute/3`'s business, not this wait's.
      refute match?({:error, :not_started}, Task.await(task, 3_000))
    end
  end

  describe "execute/4 with a connection that has no API versions yet" do
    setup do
      TestClient.stop()
      on_exit(&TestClient.stop/0)
      :ok
    end

    test "gives up on a client that is up but never picks any up" do
      _put_startup_wait(200)

      # `auto_connect: false` leaves the process and its table up with an empty versions map, so
      # this is the second half of the same start-up: the table is there, but there is still
      # nothing to resolve a request against, and here there never will be.
      assert {:ok, _pid} = TestClient.start(auto_connect: false)
      assert {:disconnected, :started} = TestConn.status()

      {elapsed, result} = TestClient.measure(fn -> TestConn.execute(:action, _request()) end)

      assert {:error, :not_started} = result
      assert elapsed >= 200
    end

    test "picks up versions that arrive during the grace period" do
      _put_startup_wait(2_000)

      assert {:ok, _pid} = TestClient.start(auto_connect: false)

      task = Task.async(fn -> TestConn.execute(:action, _request()) end)

      # Nothing is decided while the versions are still missing -- a client that is merely slow to
      # reach the graph gets the same grace period as one that is slow to start at all.
      assert nil == Task.yield(task, 200)

      # The moment they turn up the call resolves against them instead of waiting out the rest of
      # the deadline. Which API they name is beside the point; that they were used is not.
      :ets.insert(TestConn, {:versions, %{other: %{path: "", protocol: "", subprotocol: ""}}})

      assert {:error, {:unknown_api, [:other]}} = Task.await(task, 3_000)
    end
  end

  describe "__next_retry__/2" do
    test "waits out an advertised wait rather than its own curve" do
      assert {delay, 2_000} = ConnectionManager.__next_retry__(1_000, 2_000)

      assert delay > 2_000
    end

    test "falls back on the curve when nothing was advertised" do
      assert {delay, 2_000} = ConnectionManager.__next_retry__(1_000, 0)

      assert delay > 1_000
      assert delay <= 2_000
    end

    test "clamps an advertised wait above the configured ceiling" do
      _put_env(:retry_floor_max_ms, 5_000)

      {{delay, _next_current}, log} =
        with_log(fn -> ConnectionManager.__next_retry__(1_000, 3_600_000) end)

      # Parked for an hour is an outage; the ceiling buys a bounded extra denial instead.
      assert delay > 5_000
      assert delay <= 6_000

      # An operator has to be able to see that a wait was cut short.
      assert log =~ "is above :retry_floor_max_ms"
    end

    test "treats a non-positive ceiling as no ceiling at all" do
      _put_env(:retry_floor_max_ms, 0)

      assert {delay, _next_current} = ConnectionManager.__next_retry__(1_000, 90_000)

      assert delay > 90_000
    end

    test "advances the curve no further than the configured cap" do
      _put_env(:retry_max_ms, 3_000)

      assert {_delay, 3_000} = ConnectionManager.__next_retry__(2_000, 0)
    end

    test "carries the curve up to the cap and holds it there" do
      _put_env(:retry_initial_ms, 50)
      _put_env(:retry_max_ms, 200)

      currents =
        1..5
        |> Enum.scan(50, fn _attempt, current ->
          {_delay, next_current} = ConnectionManager.__next_retry__(current, 0)
          next_current
        end)

      assert [100, 200, 200, 200, 200] == currents
    end

    test "a cap of zero falls back on the seed rather than a 1ms hot loop" do
      _put_env(:retry_max_ms, 0)

      assert {delay, 1_000} = ConnectionManager.__next_retry__(1_000, 0)

      assert delay > 500
    end

    test "a negative cap falls back on the seed rather than a 1ms hot loop" do
      _put_env(:retry_max_ms, -1)

      assert {delay, 1_000} = ConnectionManager.__next_retry__(1_000, 0)

      assert delay > 500
    end
  end

  describe "__refresh_in__/2" do
    @now 1_000_000

    test "leaves a token most of its life before refreshing it" do
      # 20 minutes: 5% is 60_000, comfortably above the floor, so the ratio decides.
      assert 1_140_000 == ConnectionManager.__refresh_in__(@now + 1_200_000, @now)
    end

    test "keeps a short token's margin wide enough to outlive a run of denials" do
      # 5% of a minute is 3_000ms -- less than a single backoff ceiling, so the floor decides.
      assert 30_000 == ConnectionManager.__refresh_in__(@now + 60_000, @now)
    end

    test "widens the margin when the backoff ceiling is raised" do
      # The floor is derived from the ceiling rather than picked, so raising the ceiling cannot
      # leave the margin too narrow to cover the backoff it now permits.
      _put_env(:retry_max_ms, 20_000)

      assert 540_000 == ConnectionManager.__refresh_in__(@now + 600_000, @now)
    end

    test "halves a token whose lifetime exactly matches the margin" do
      # The boundary that decides between a margin and a hot loop: subtracting a 30_000 margin
      # from a 30_000 lifetime is a refresh scheduled 0ms out, which re-authenticates in a tight
      # loop against the very endpoint this backoff exists to protect.
      assert 15_000 == ConnectionManager.__refresh_in__(@now + 30_000, @now)
    end

    test "halves a token whose lifetime is shorter than the margin" do
      refresh_in = ConnectionManager.__refresh_in__(@now + 20_000, @now)

      assert 10_000 == refresh_in
      assert refresh_in > 0
    end

    test "keeps a token a hair over the margin off a tight refresh loop" do
      # The margin is a floor on the wait, not a cliff to fall off the far side of: one millisecond
      # more life must not buy a 1ms refresh that re-authenticates forever.
      assert 15_000 == ConnectionManager.__refresh_in__(@now + 30_001, @now)
    end

    test "keeps a token just over a widened margin off a tight refresh loop" do
      _put_env(:retry_max_ms, 20_000)

      assert 30_000 == ConnectionManager.__refresh_in__(@now + 60_001, @now)
    end

    test "stays positive for a lifetime too short to halve" do
      # Integer division takes 1ms to 0, which is the same hot loop by a different route.
      assert 1 == ConnectionManager.__refresh_in__(@now + 1, @now)
    end

    test "hands a non-negative wait back for a token that has already expired" do
      # Clock skew is enough to see this, and `Process.send_after/3` raises on a negative wait --
      # which takes the manager down with the whole :one_for_all subtree behind it.
      assert 0 == ConnectionManager.__refresh_in__(@now - 5_000, @now)
    end

    test "honours a configured refresh ratio" do
      _put_env(:token_refresh_ratio, 0.5)

      assert 300_000 == ConnectionManager.__refresh_in__(@now + 600_000, @now)
    end
  end

  describe "authenticating through a run of denials" do
    setup do
      TestClient.stop()

      on_exit(fn ->
        Mock.clear_rate_limit("action_invoker")
        TestClient.stop()
      end)

      :ok
    end

    test "grows the wait between successive denials and still gets there" do
      _put_env(:retry_initial_ms, 20)
      _put_env(:retry_max_ms, 400)
      Mock.rate_limit_auth("action_invoker", 6, :no_hint)

      {{elapsed, _ready}, log} =
        with_log(fn ->
          TestClient.measure(fn ->
            assert {:ok, _sup_pid} = TestClient.start()
            assert_receive {:conn_status_changed, :ready}, 10_000
          end)
        end)

      # Names the site and the delay actually chosen. Every site logs the same "429 received"
      # line from `RetryAfter`, so without this an operator cannot tell which one is backing off
      # or what it settled on after the floor and the cap.
      assert log =~ "Retrying authentication in"

      # Six denials on a curve seeded at 20ms and capped at 400ms wait jitter(40), jitter(80),
      # jitter(160), jitter(320), jitter(400), jitter(400) -- so the run cannot finish inside
      # 700ms, whereas a curve that never advanced would be six waits of at most 40ms.
      #
      # Lower bound only, for the same reason as the feature scenario: load can only push this
      # up, and the cap is pinned arithmetically by "carries the curve up to the cap" above.
      assert elapsed > 700
    end
  end

  describe "discovering versions through a run of denials" do
    setup do
      TestClient.stop()

      on_exit(fn ->
        Mock.clear_rate_limit(:versions)
        TestClient.stop()
      end)

      :ok
    end

    test "grows the wait between successive denials instead of restarting the curve" do
      _put_env(:retry_initial_ms, 20)
      _put_env(:retry_max_ms, 400)
      Mock.rate_limit_versions(6, :no_hint)

      {{elapsed, _ready}, log} =
        with_log(fn ->
          TestClient.measure(fn ->
            assert {:ok, _sup_pid} = TestClient.start()
            assert_receive {:conn_status_changed, :ready}, 10_000
          end)
        end)

      assert log =~ "Retrying API version discovery in"

      # Same arithmetic as the authentication run: six denials seeded at 20ms and capped at 400ms
      # wait jitter(40) through jitter(400), so the run lands in 700ms-1400ms and cannot finish
      # inside 700ms. What that catches is a curve that RE-SEEDS on each attempt -- six waits of
      # at most 40ms, ~185ms in total. It does not catch the flat one second this path used to
      # wait, which is slower rather than faster; the acceptance scenario covers that one.
      assert elapsed > 700
    end
  end

  describe "opening a WebSocket connection that the graph refuses" do
    setup do
      TestClient.stop()

      on_exit(fn ->
        Mock.clear_rate_limit({:ws_upgrade, "invoker"})
        TestClient.stop()
      end)

      :ok
    end

    test "survives an upgrade failure that is not a 429" do
      assert {:ok, _sup_pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000
      manager = _manager_pid()
      assert is_pid(manager)

      # 503 with no retry-after: the catch-all clause, not the rate-limited one. This is the
      # load-bearing case -- any upgrade failure used to reach a CaseClauseError here.
      Mock.reject_ws_upgrade("invoker", 1, 503, :no_hint)

      # The caller is told what actually happened. Calling this a rate limit would be a lie, and
      # would also regress a path that spins and recovers today.
      assert {:error, {:upgrade_refused, 503}} = TestConn.execute(:"action-ws", _request())

      assert manager == _manager_pid()
      assert Process.alive?(manager)
    end

    test "answers a caller straight away instead of spinning until the reopen lands" do
      assert {:ok, _sup_pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000

      # Open the connection for real, so its ETS entry exists and can go nil underneath us.
      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
      assert [{_key, conn_pid}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})
      assert is_pid(conn_pid)

      # Given the graph will refuse the reopen, asking for two seconds
      Mock.reject_ws_upgrade("invoker", 1, 429, 2)

      # When the live connection dies, so the manager reopens it and is refused
      Process.exit(conn_pid, :kill)
      _await_pending_reopen(:"action-ws", System.monotonic_time(:millisecond) + 5_000)

      # Then a caller is answered immediately. Without the pending stamp this is the unbounded
      # `Process.sleep(5)` spin: every caller parks for the whole backoff and gets `:ok` late.
      assert {:error, {:rate_limited, _retry_after_ms}} =
               TestConn.execute(:"action-ws", _request())
    end

    test "gives up on a forced open for a client that never wanted the connection" do
      # The door arms `:reopen_ws` so that `desired_status` can drop it after one retry. Arming the
      # dropped-socket message here instead would retry a refused open for ever.
      _put_env(:retry_initial_ms, 100)
      _put_env(:retry_max_ms, 200)

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000
      assert :ok = GenServer.call(_manager_pid(), :refresh_token)

      Mock.reject_ws_upgrade("invoker", 20, 503, :no_hint)

      {_result, log} =
        with_log(fn ->
          GraphConn.open_ws_connection(TestConn, :"action-ws")
          Process.sleep(1_500)
        end)

      # Non-vacuity: assert the mock's own line, not the bare status, which a jittered delay of
      # "1503ms" would satisfy by accident.
      assert log =~ "Rejecting upgrade with 503"

      retries =
        ~r/Retrying action-ws WS upgrade in/
        |> Regex.scan(log)
        |> length()

      assert 1 == retries
    end

    test "leaves no hold behind after an upgrade failure that is not a rate limit" do
      assert {:ok, _sup_pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000

      Mock.reject_ws_upgrade("invoker", 1, 503, :no_hint)

      assert {:error, {:upgrade_refused, 503}} = TestConn.execute(:"action-ws", _request())

      assert [{_key, nil}] = :ets.lookup(TestConn, {:"action-ws", :reopen_at})
    end

    test "keeps later callers on the stamp for an api that never connected" do
      assert {:ok, _sup_pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000

      # One rejection only. The api has never been opened, so its conn_pid row does not exist --
      # which is the shape a fresh client has for every WS api it has not used yet.
      Mock.reject_ws_upgrade("invoker", 1, 429, 2)

      assert {:error, {:rate_limited, _first}} = TestConn.execute(:"action-ws", _request())

      # The second caller must read the stamp, not mount another upgrade. Mounting one would
      # consume the arm and succeed here -- and in production would re-hit the limiter once per
      # caller, so the retry rate would scale with caller volume instead of the curve.
      assert {:error, {:rate_limited, _second}} = TestConn.execute(:"action-ws", _request())
    end

    test "refuses a public open while a hold is in effect" do
      assert {:ok, _sup_pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000

      Mock.reject_ws_upgrade("invoker", 1, 429, 2)
      assert {:error, {:rate_limited, _held}} = TestConn.execute(:"action-ws", _request())

      # `open_ws_connection/2` is the door consumers actually use -- anything reopening a downed
      # WS from `on_status_change/3` comes through here. Unguarded it mounts a real upgrade and
      # leaves another reopen timer behind, so the retry rate follows caller volume.
      GraphConn.open_ws_connection(TestConn, :"action-ws")

      refute_receive {:conn_status_changed, :"action-ws", :ready}, 500
      assert [{_key, nil}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})
    end

    test "reports no wait left once the reopen window has already passed" do
      assert {:ok, _sup_pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000
      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000

      # A connection that is down with a stamp that has expired: the window is over, so the
      # answer is "retry now" rather than a negative number leaking out of the arithmetic.
      :ets.insert(TestConn, {{:"action-ws", :conn_pid}, nil})
      :ets.insert(TestConn, {{:"action-ws", :reopen_at}, _monotonic_ms_ago(5_000)})

      assert {:error, {:rate_limited, 0}} == TestConn.execute(:"action-ws", _request())
    end
  end

  describe "a reopen timer that fires" do
    setup do
      table = :"reopen_guard_#{System.unique_integer([:positive])}"
      :ets.new(table, [:named_table, :public])

      {:ok, table: table}
    end

    test "is dropped when the connection is no longer wanted", %{table: table} do
      # `desired_status` other than `:ready` means nobody wants this connection, so a timer left
      # over from before must not quietly bring it back.
      state = _ws_state(table, :ready, {:disconnected, :started})
      :ets.insert(table, {{:"action-ws", :reopen_at}, 12_345})

      assert {:noreply, ^state} =
               ConnectionManager.handle_info({:reopen_ws, :"action-ws", 100, {:hold, 0}}, state)

      # The stamp goes with it, so callers stop being told to back off.
      assert [{{:"action-ws", :reopen_at}, nil}] =
               :ets.lookup(table, {:"action-ws", :reopen_at})

      refute_received {:reopen_ws, _api, _retry_in, _hold}
    end

    test "is re-scheduled, not dropped, while the client is still starting up", %{table: table} do
      # Wanted, but `status` is not `:ready` yet. `status` never regresses from `:ready`, so this
      # is the start-up window -- versions in, token not yet -- and the ETS token is
      # nil-initialised. Dropping would lose the connection entirely.
      state = _ws_state(table, :got_api_versions, :ready)

      assert {:noreply, ^state} =
               ConnectionManager.handle_info({:reopen_ws, :"action-ws", 100, {:hold, 0}}, state)

      # The stamp moves with the reschedule. Checked before the timer fires, because it expires
      # exactly when it does: left stale it is already in the past, so `_await_ws_connection`
      # answers "retry now" for the whole window and a consumer honouring it hot-loops.
      assert [{_key, reopen_at}] = :ets.lookup(table, {:"action-ws", :reopen_at})
      assert reopen_at > System.monotonic_time(:millisecond)

      # Comes back on an advanced curve rather than the seed.
      assert_receive {:reopen_ws, :"action-ws", 200, {:hold, 0}}, 1_000
    end

    test "never leaves a hold that outlives the reopen it was scheduled with", %{table: table} do
      # `handle_call/3` refuses a public open while a hold is in force, so a reopen that arrived
      # to find its OWN hold still standing would be refused by the stamp it exists to clear.
      # Nothing guards against that -- the structure prevents it, because one delay feeds both
      # the timer and the stamp. Stamping the advertised wait instead of the chosen delay is the
      # edit that would break it, so the advertised wait here is far above the ceiling that
      # clamps it.
      _put_env(:retry_floor_max_ms, 300)
      state = _ws_state(table, :got_api_versions, :ready)

      assert {:noreply, ^state} =
               ConnectionManager.handle_info(
                 {:reopen_ws, :"action-ws", 100, {:hold, 5_000}},
                 state
               )

      # Both directions, so this test does not depend on its sibling above. Too FAR in the future
      # and the reopen is refused by its own hold; expiring too EARLY lets a public open through
      # mid-hold, which is the amplifier the guard exists to stop.
      assert [{_key, stamped_at}] = :ets.lookup(table, {:"action-ws", :reopen_at})
      assert stamped_at > System.monotonic_time(:millisecond)

      assert_receive {:reopen_ws, :"action-ws", _next, {:hold, 5_000}}, 5_000

      assert [{_key, reopen_at}] = :ets.lookup(table, {:"action-ws", :reopen_at})
      assert reopen_at <= System.monotonic_time(:millisecond)
    end
  end

  describe "a token whose expires-at is not a timestamp" do
    setup do
      TestClient.stop()
      TestClient.put_env(:mock_expires_at, %{})
      TestClient.put_env(:mock_auth_bodies, %{})
      on_exit(&TestClient.stop/0)

      :ok
    end

    test "keeps the client up and retries, rather than taking its subtree down" do
      Mock.put_expires_at("action_invoker", "1758723600000")

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000

      manager = _manager_pid()
      assert is_pid(manager)

      # `Jason.decode!/1` hands back whatever the Graph sent, and the spec's `pos_integer()` is
      # documentation rather than a guarantee. Arithmetic on a string raises inside the manager,
      # which takes the client's subtree with it; a paced retry is the graceful answer.
      {reply, log} = with_log(fn -> GenServer.call(manager, :refresh_token) end)

      assert :ok == reply
      assert log =~ "authentication"
      assert Process.alive?(manager)
      assert manager == _manager_pid()
    end

    test "names the expires-at it refused, so the retry loop is not silent" do
      Mock.put_expires_at("action_invoker", "1758723600000")

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000

      {_reply, log} = with_log(fn -> GenServer.call(_manager_pid(), :refresh_token) end)

      # The refusal carries the offending value precisely so it can be named. Without it an
      # operator sees a client retrying authentication forever and nothing saying why.
      assert log =~ "invalid_expires_at"
    end

    test "keeps the client up when the Graph names the expiry in microseconds" do
      # A valid integer, so the type guard passes it, and the unit slip a Graph that changes its
      # clock precision actually makes. The already-expired clause names the slip in the other
      # direction; this one reaches `Process.send_after/3` with a delay it refuses, inside the
      # manager, under `:one_for_all`.
      Mock.put_expires_at(
        "action_invoker",
        DateTime.utc_now() |> DateTime.to_unix(:microsecond)
      )

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000

      manager = _manager_pid()

      reply =
        try do
          GenServer.call(manager, :refresh_token)
        catch
          :exit, reason -> {:exit, reason}
        end

      assert :ok == reply
      assert Process.alive?(manager)
    end

    test "names an expiry so far out it cannot be a millisecond timestamp" do
      # The slip DOWNWARD has always had a warning naming the likely cause. This one is clamped
      # rather than raising, so the client stays up either way -- without a warning of its own a
      # Graph sending microseconds would look exactly like one that works.
      Mock.put_expires_at(
        "action_invoker",
        DateTime.utc_now() |> DateTime.to_unix(:microsecond)
      )

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000

      {reply, log} = with_log(fn -> GenServer.call(_manager_pid(), :refresh_token) end)

      assert :ok == reply
      assert log =~ "expires-at"
    end

    test "keeps the client up when the Graph answers 200 with no expires-at at all" do
      Mock.put_expires_at("action_invoker", :absent)

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000

      manager = _manager_pid()
      {reply, log} = with_log(fn -> GenServer.call(manager, :refresh_token) end)

      assert :ok == reply
      assert log =~ "invalid_auth_response"
      assert Process.alive?(manager)
    end

    test "keeps the client up when the Graph answers 200 with a body that is not JSON" do
      Mock.put_auth_body("action_invoker", "<html><body>502 Bad Gateway</body></html>")

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000

      manager = _manager_pid()
      {reply, log} = with_log(fn -> GenServer.call(manager, :refresh_token) end)

      assert :ok == reply
      assert log =~ "invalid_auth_response"
      assert Process.alive?(manager)
    end

    test "takes a timestamp the Graph wrote with a decimal point" do
      # A future expiry, so the already-expired branch cannot absorb it: the refresh maths is what
      # has to survive the float.
      future =
        DateTime.utc_now()
        |> DateTime.to_unix(:millisecond)
        |> Kernel.+(600_000)
        |> Kernel.*(1.0)

      Mock.put_expires_at("action_invoker", future)

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000

      # Reaching `:ready` is the load-bearing part: a rejected timestamp would schedule a retry
      # and leave the client without a token, which is also a manager that survives.
      assert :ok = GenServer.call(_manager_pid(), :refresh_token)
      assert_receive {:conn_status_changed, :ready}, 15_000
    end
  end

  describe "a token that arrives already expired" do
    setup do
      TestClient.stop()
      on_exit(&TestClient.stop/0)
      :ok
    end

    test "keeps refreshing on an escalating curve instead of stopping after one attempt" do
      # The FIRST refresh here is scheduled by the connect flow. Carrying `:connect` through to it
      # would see it dropped at `:ready`, and the client would never refresh again.
      _expire_token_for("action_invoker")
      _put_env(:retry_initial_ms, 100)
      _put_env(:retry_max_ms, 2_000)

      {_result, log} =
        with_log(fn ->
          assert {:ok, _sup_pid} = TestClient.start()
          assert_receive {:conn_status_changed, :ready}, 15_000
          Process.sleep(4_000)
        end)

      delays =
        ~r/Retrying token refresh in (\d+)ms/
        |> Regex.scan(log)
        |> Enum.map(fn [_line, ms] -> String.to_integer(ms) end)

      assert length(delays) >= 4
      assert List.last(delays) > 2 * List.first(delays)
    end

    test "does not re-authenticate in a hot loop" do
      # Reachable with a perfectly synchronised clock: a graph emitting `expires-at` in seconds
      # rather than milliseconds reads as decades in the past.
      _expire_token_for("action_invoker")
      _put_env(:retry_initial_ms, 100)
      _put_env(:retry_max_ms, 200)

      {_result, log} =
        with_log(fn ->
          assert {:ok, _sup_pid} = TestClient.start()
          Process.sleep(1_000)
        end)

      attempts =
        ~r/Authenticating\.\.\./
        |> Regex.scan(log)
        |> length()

      assert attempts <= 20

      # The condition has to be diagnosable: neither this nor the crash it replaced ever said why.
      assert log =~ "arrived already expired"
    end
  end

  describe "a WebSocket connection that drops" do
    setup do
      TestClient.stop()

      on_exit(fn ->
        Mock.clear_rate_limit({:ws_upgrade, "invoker"})
        TestClient.stop()
      end)

      :ok
    end

    test "brings a dropped socket back even when its first reopen is refused" do
      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000

      # What a 401 on any REST call does in production, and the only thing that puts a real token
      # on a client whose `desired_status` never reaches `:ready`.
      assert :ok = GenServer.call(_manager_pid(), :refresh_token)

      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
      assert [{_key, conn_pid}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})
      assert is_pid(conn_pid)

      # One refusal only, so the attempt after it would succeed. Recovery must survive a reopen
      # that fails: the retry it schedules is the one that actually brings the socket back.
      Mock.reject_ws_upgrade("invoker", 1, 503, :no_hint)
      Process.exit(conn_pid, :kill)

      assert_receive {:conn_status_changed, :"action-ws", :ready}, 25_000
    end

    test "brings a dropped socket back even when its first reopen is rate limited" do
      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000
      assert :ok = GenServer.call(_manager_pid(), :refresh_token)

      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
      assert [{_key, conn_pid}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})

      # The 429 recovery path arms its own retry too, and it has to stay on the same message as
      # the plain-failure one or the hold outlives the socket it was meant to pace.
      Mock.reject_ws_upgrade("invoker", 1, 429, 2)
      Process.exit(conn_pid, :kill)

      assert_receive {:conn_status_changed, :"action-ws", :ready}, 25_000
    end

    test "waits out a paced reopen instead of telling the caller the connection is down" do
      _put_env(:retry_initial_ms, 1_000)
      _put_startup_wait(500)

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000
      assert :ok = GenServer.call(_manager_pid(), :refresh_token)

      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
      assert [{_key, conn_pid}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})

      Process.exit(conn_pid, :kill)
      _await_conn_pid_cleared(:"action-ws", System.monotonic_time(:millisecond) + 5_000)

      # The reopen is paced into (1_000, 2_000], and `:startup_wait_ms` defaults to 500. A caller
      # that only waits the shorter of the two is told the connection is down while the client is
      # a second away from bringing it back.
      assert :ok = TestConn.execute(:"action-ws", _request())
    end

    test "stops at the reopen it first saw rather than following an escalating curve" do
      # A short seed under a high ceiling, so every refused reopen roughly doubles the next due
      # time. A caller that re-read the due time on each poll would be dragged along the whole
      # curve; one that reads it once is bounded by the reopen it arrived on.
      _put_startup_wait(500)
      _put_env(:retry_initial_ms, 100)
      _put_env(:retry_max_ms, 100_000)

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000
      assert :ok = GenServer.call(_manager_pid(), :refresh_token)

      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
      assert [{_key, conn_pid}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})

      Mock.reject_ws_upgrade("invoker", 10, 503, :no_hint)
      Process.exit(conn_pid, :kill)
      _await_conn_pid_cleared(:"action-ws", System.monotonic_time(:millisecond) + 5_000)

      {elapsed, result} = TestClient.measure(fn -> TestConn.execute(:"action-ws", _request()) end)

      assert {:error, :ws_connection_down} = result

      # The first reopen is due inside 200ms and the grace period is 500, so the budget is under a
      # second. The steps after it are 400, 800, 1_600ms and climbing.
      assert elapsed < 1_500
    end

    test "answers a rate limit straight away instead of waiting out its reopen" do
      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000
      assert :ok = GenServer.call(_manager_pid(), :refresh_token)

      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
      assert [{_key, conn_pid}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})

      # The drop's own reopen is refused with a 429, which stamps a hold and paces the reopen
      # after it a further two seconds out.
      Mock.reject_ws_upgrade("invoker", 1, 429, 2)
      Process.exit(conn_pid, :kill)
      _await_pending_reopen(:"action-ws", System.monotonic_time(:millisecond) + 10_000)

      {elapsed, result} = TestClient.measure(fn -> TestConn.execute(:"action-ws", _request()) end)

      assert {:error, {:rate_limited, _ms}} = result

      # The advertised wait is the caller's to honour, not time to spend inside `execute/4`.
      assert elapsed < 500
    end

    test "leaves no hold behind after a socket simply drops" do
      assert {:ok, _sup_pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000

      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
      assert [{_key, conn_pid}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})

      Process.exit(conn_pid, :kill)
      _await_conn_pid_cleared(:"action-ws", System.monotonic_time(:millisecond) + 5_000)

      # A drop is not a rate limit. Stamping one would hand every later caller
      # `{:error, {:rate_limited, ms}}` for a wait the graph never asked for.
      assert [{_key, nil}] = :ets.lookup(TestConn, {:"action-ws", :reopen_at})
    end

    test "paces the reopen instead of reconnecting the instant the socket dies" do
      assert {:ok, _sup_pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000

      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
      assert [{_key, conn_pid}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})
      assert is_pid(conn_pid)

      Process.exit(conn_pid, :kill)

      # Nothing advertised a wait, so no hold is stamped and the 429 guard cannot see this drop
      # at all. An unpaced reopen re-presents whatever token is in ETS as fast as the graph will
      # answer, which is the loop an expired token turns into. The seed doubles to 2_000 and
      # jitters over (1_000, 2_000], so the curve cannot deliver a reopen inside this window.
      refute_receive {:conn_status_changed, :"action-ws", :ready}, 500

      # Paced, not abandoned.
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
    end

    test "brings a dropped socket back for a client that never wanted a full connection" do
      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 15_000

      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
      assert [{_key, conn_pid}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})
      assert is_pid(conn_pid)

      Process.exit(conn_pid, :kill)

      # This client asked for the socket by hand, so `desired_status` says nothing about whether
      # it still wants it. Pacing the reopen must not quietly turn into dropping it.
      assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
    end

    test "leaves a pending reopen alone rather than scheduling a second one" do
      assert {:ok, _sup_pid} = TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000

      # A reopen is already pending and owns a timer of its own. Arming another off the same
      # close would reopen twice and, on a rate-limited api, re-hit the limiter for free.
      held_until = System.monotonic_time(:millisecond) + 60_000
      :ets.insert(TestConn, {{:"action-ws", :reopen_at}, held_until})

      dead_pid = spawn(fn -> :ok end)

      state = %ConnectionManager.State{
        base_name: TestConn,
        ws_connections: %{dead_pid => :"action-ws"},
        status: :ready,
        desired_status: :ready
      }

      assert {:noreply, _state} =
               ConnectionManager.handle_info(
                 {:DOWN, make_ref(), :process, dead_pid, :killed},
                 state
               )

      assert [{_key, ^held_until}] = :ets.lookup(TestConn, {:"action-ws", :reopen_at})
      refute_received {:reopen_ws, _api, _retry_in, _hold}
    end
  end

  # The :DOWN handler and the refused reopen both happen asynchronously, so wait for the stamp
  # rather than sleeping a guessed amount.
  defp _await_pending_reopen(api, deadline) do
    TestConn
    |> :ets.lookup({api, :reopen_at})
    |> case do
      [{_key, reopen_at}] when is_integer(reopen_at) ->
        :ok

      _not_pending_yet ->
        assert System.monotonic_time(:millisecond) < deadline,
               "no reopen was ever marked pending for #{api}"

        Process.sleep(10)
        _await_pending_reopen(api, deadline)
    end
  end

  # Through the public arming API rather than the env key, so the surface consumers would use is
  # the one under test. `_put_env` registers the restore.
  defp _expire_token_for(token) do
    _put_env(:mock_token_lifetimes, %{})
    Mock.put_token_lifetime(token, -60_000)
  end

  defp _await_conn_pid_cleared(api, deadline) do
    TestConn
    |> :ets.lookup({api, :conn_pid})
    |> case do
      [{_key, nil}] ->
        :ok

      _still_open ->
        assert System.monotonic_time(:millisecond) < deadline,
               "#{api} never had its connection cleared"

        Process.sleep(10)
        _await_conn_pid_cleared(api, deadline)
    end
  end

  # The name is built from a string on purpose: `ConnectionManager` is aliased in this module, so
  # `Module.concat(TestConn, ConnectionManager)` would expand to the wrong name and return nil.
  describe "__refresh_call_timeout__/1" do
    test "outlasts the authentication call it waits on" do
      assert 61_000 == ConnectionManager.__refresh_call_timeout__(auth: [timeout: 60_000])
    end

    test "outlasts the authentication default when none is configured" do
      assert 61_000 == ConnectionManager.__refresh_call_timeout__(auth: [])
    end
  end

  describe "status/2" do
    setup do
      TestClient.stop()
      {:ok, _supervisor} = TestClient.start()
      _await_manager(System.monotonic_time(:millisecond) + 2_000)
      on_exit(&TestClient.stop/0)
      :ok
    end

    test "gives up after the caller's timeout rather than the hardcoded default" do
      manager = _manager_pid()
      :ok = :sys.suspend(manager)
      # Whether it is still there is a race with its own supervisor, and a dead one needs no
      # resuming either way.
      on_exit(fn ->
        try do
          :sys.resume(manager)
        catch
          :exit, _already_gone -> :ok
        end
      end)

      {elapsed, result} =
        TestClient.measure(fn -> catch_exit(ConnectionManager.status(TestConn, 100)) end)

      assert {:timeout, {GenServer, :call, [_manager_name, :status, 100]}} = result
      assert elapsed < 1_000
    end
  end

  describe "refresh_token when the Graph rejects the credentials" do
    setup do
      TestClient.stop()
      {:ok, _supervisor} = TestClient.start()
      _await_manager(System.monotonic_time(:millisecond) + 2_000)
      on_exit(&TestClient.stop/0)
      :ok
    end

    test "answers the caller instead of dying on the reply shape" do
      _reject_next_authentication()

      assert {:error, :wrong_credentials} = GenServer.call(_manager_pid(), :refresh_token)
    end
  end

  describe "a WebSocket connection the server closes" do
    setup do
      TestClient.stop()

      on_exit(fn ->
        Mock.clear_rate_limit({:ws_upgrade, "invoker"})
        TestClient.stop()
      end)

      :ok
    end

    test "escalates across accept-then-close cycles rather than pacing flat forever" do
      _put_env(:retry_initial_ms, 100)
      _put_env(:stability_window_ms, 60_000)
      _open_action_ws()

      # A socket that is accepted and dropped straight back has not proved anything, so the curve
      # it came back on is the one the next reopen continues from. Read the curve rather than the
      # time left until the reopen: the latter is how much of the delay has not elapsed yet, which
      # depends on how fast the test got there and goes negative once the reopen has fired.
      curves = Enum.map(1..3, fn _cycle -> _close_and_read_curve() end)

      assert [200, 400, 800] == curves
    end

    test "returns the curve to its seed once a socket has stayed up long enough" do
      _put_env(:retry_initial_ms, 100)
      # Wide enough that the test's own wall clock between cycles cannot be mistaken for a socket
      # proving itself -- with a short window a slow cycle resets the curve and the escalation
      # below never happens.
      _put_env(:stability_window_ms, 60_000)
      _open_action_ws()

      # Two accept-then-close cycles put the curve past its seed. The curve is the doubling
      # itself, with no jitter on it, so these are exact rather than bands that can overlap.
      Enum.each(1..2, fn _cycle -> _close_and_read_curve() end)
      assert 400 == _reopen_curve(:"action-ws")

      _await_conn_pid(:"action-ws", System.monotonic_time(:millisecond) + 25_000)

      # Only now does staying up mean anything, and the sleep clears the window deliberately.
      _put_env(:stability_window_ms, 200)
      Process.sleep(400)

      _close_and_read_curve()

      assert 200 == _reopen_curve(:"action-ws")
    end

    test "keeps a healthy socket's stability clock when a consumer re-opens it" do
      _put_env(:retry_initial_ms, 100)
      _put_env(:stability_window_ms, 200)
      _open_action_ws()

      _close_and_read_curve()
      _await_conn_pid(:"action-ws", System.monotonic_time(:millisecond) + 25_000)
      Process.sleep(400)

      # Asking for a connection that is already up is how a consumer reopens a socket it cannot
      # tell is down. It hands back the live one, and must not restart the clock that decides
      # whether the socket has proved itself.
      GraphConn.open_ws_connection(TestConn, :"action-ws")
      assert :ready = GenServer.call(_manager_pid(), :status)

      _close_and_read_curve()

      assert 200 == _reopen_curve(:"action-ws")
    end

    test "measures stability against the backoff ceiling rather than a fixed window" do
      _put_env(:retry_initial_ms, 100)
      # A ceiling high enough that the window cannot be reached during the cycles: they would
      # otherwise reset the curve they are meant to escalate if one of them ran slowly.
      _put_env(:retry_max_ms, 100_000)
      _open_action_ws()

      # Two cycles first, to put the curve where carrying and starting over give different
      # numbers.
      Enum.each(1..2, fn _cycle -> _close_and_read_curve() end)
      assert 400 == _reopen_curve(:"action-ws")

      _await_conn_pid(:"action-ws", System.monotonic_time(:millisecond) + 25_000)

      # Only now does the ceiling matter: 400 makes the window 1_200ms, which the sleep clears.
      _put_env(:retry_max_ms, 400)
      Process.sleep(1_400)

      _close_and_read_curve()

      assert 200 == _reopen_curve(:"action-ws")
    end

    test "stops reopening when the close says the token itself was refused" do
      _open_action_ws()

      Mock.close_ws_connection("invoker", 1008, "token rejected")

      _await_conn_pid_cleared(:"action-ws", System.monotonic_time(:millisecond) + 15_000)

      # Reconnecting with a token the server just refused can only be refused again.
      refute_receive {:conn_status_changed, :"action-ws", :ready}, 5_000
      assert [{_key, nil}] = :ets.lookup(TestConn, {:"action-ws", :reopen_at})
    end

    test "reopens a refused connection once a new token arrives" do
      _open_action_ws()

      Mock.close_ws_connection("invoker", 1008, "token rejected")
      _await_conn_pid_cleared(:"action-ws", System.monotonic_time(:millisecond) + 15_000)
      refute_receive {:conn_status_changed, :"action-ws", :ready}, 2_000

      # The token was what the Graph refused, so a fresh one is the event that makes reconnecting
      # worth trying again. A handler never sends a request of its own to trigger it.
      assert :ok = GenServer.call(_manager_pid(), :refresh_token)

      _await_conn_pid(:"action-ws", System.monotonic_time(:millisecond) + 25_000)
    end

    test "still reopens when the close is an ordinary one" do
      _open_action_ws()

      Mock.close_ws_connection("invoker", 1011, "go away for now")

      _await_conn_pid_cleared(:"action-ws", System.monotonic_time(:millisecond) + 15_000)
      _await_conn_pid(:"action-ws", System.monotonic_time(:millisecond) + 25_000)
    end
  end

  # Drops the socket and reports the curve the reopen it schedules was placed on. The curve is the
  # doubling itself, carrying no jitter and no wall clock, so it is exact.
  defp _close_and_read_curve do
    _await_registered_sockets("invoker", 1, System.monotonic_time(:millisecond) + 25_000)
    Mock.close_ws_connection("invoker", 1011, "go away for now")
    # Not `conn_pid` going nil: the `:DOWN` handler clears that BEFORE it schedules the reopen, so
    # a read landing in the gap returns the previous cycle's curve. The due time is written in the
    # same breath as the curve, so it is the one stamp that says this cycle's is current.
    _await_reopen_scheduled(:"action-ws", System.monotonic_time(:millisecond) + 15_000)

    _reopen_curve(:"action-ws")
  end

  defp _await_reopen_scheduled(api, deadline) do
    TestConn
    |> :ets.lookup({api, :reopen_due_at})
    |> case do
      [{_key, due_at}] when is_integer(due_at) ->
        :ok

      _not_scheduled_yet ->
        assert System.monotonic_time(:millisecond) < deadline, "#{api} reopen was never scheduled"
        Process.sleep(5)
        _await_reopen_scheduled(api, deadline)
    end
  end

  defp _reopen_curve(api) do
    [{_key, curve}] = :ets.lookup(TestConn, {api, :reopen_curve})

    curve
  end

  defp _await_conn_pid(api, deadline) do
    TestConn
    |> :ets.lookup({api, :conn_pid})
    |> case do
      [{_key, conn_pid}] when is_pid(conn_pid) ->
        :ok

      _not_back_yet ->
        assert System.monotonic_time(:millisecond) < deadline, "#{api} never reopened"
        Process.sleep(10)
        _await_conn_pid(api, deadline)
    end
  end

  # The mock's socket registers itself only once cowboy runs its init, which is after gun has
  # already reported the upgrade -- so `:ready` is not yet proof that a close can be aimed at it,
  # and a socket from a previous test can still be holding the name.
  defp _open_action_ws do
    _await_registered_sockets("invoker", 0, System.monotonic_time(:millisecond) + 15_000)

    assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
    assert_receive {:conn_status_changed, :got_api_versions}, 15_000
    assert :ok = GenServer.call(_manager_pid(), :refresh_token)

    GraphConn.open_ws_connection(TestConn, :"action-ws")
    assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
    _await_registered_sockets("invoker", 1, System.monotonic_time(:millisecond) + 15_000)
  end

  defp _await_registered_sockets(client_type, expected, deadline) do
    Registry.TestSockets
    |> Registry.lookup({:client, client_type})
    |> length()
    |> case do
      ^expected ->
        :ok

      other ->
        assert System.monotonic_time(:millisecond) < deadline,
               "#{client_type} had #{other} sockets registered, expected #{expected}"

        Process.sleep(10)
        _await_registered_sockets(client_type, expected, deadline)
    end
  end

  defp _await_manager(deadline) do
    cond do
      is_pid(_manager_pid()) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10) and _await_manager(deadline)

      true ->
        raise "TestConn manager never started"
    end
  end

  defp _reject_next_authentication do
    [{:config, config}] = :ets.lookup(TestConn, :config)

    auth =
      config
      |> Keyword.fetch!(:auth)
      |> Keyword.put(:credentials,
        client_id: "nope",
        client_secret: "nope",
        username: "nope",
        password: "nope"
      )

    true = :ets.insert(TestConn, {:config, Keyword.put(config, :auth, auth)})
    :ok
  end

  defp _manager_pid do
    TestConn
    |> Module.concat("ConnectionManager")
    |> Process.whereis()
  end

  defp _monotonic_ms_ago(ms),
    do: System.monotonic_time(:millisecond) - ms

  defp _ws_state(base_name, status, desired_status) do
    %ConnectionManager.State{
      base_name: base_name,
      ws_connections: %{},
      status: status,
      desired_status: desired_status
    }
  end

  defp _request, do: %Request{path: "capabilities"}

  defp _put_startup_wait(ms),
    do: _put_env(:startup_wait_ms, ms)

  defp _put_env(key, value),
    do: TestClient.put_env(key, value)
end
