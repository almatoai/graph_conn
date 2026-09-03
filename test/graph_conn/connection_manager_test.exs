defmodule GraphConn.ConnectionManagerTest do
  use ExUnit.Case, async: false

  alias GraphConn.{Request, TestConn}

  describe "execute/4 with no connection running" do
    setup do
      _stop_conn()
      on_exit(&_stop_conn/0)
      :ok
    end

    test "gives up on a client that isn't coming instead of blocking forever" do
      _put_startup_wait(200)

      {elapsed, result} = _measure(fn -> TestConn.execute(:action, _request()) end)

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

      {elapsed, result} = _measure(fn -> TestConn.execute(:action, _request()) end)

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
      assert {:ok, _pid} = _start_conn()
      assert_receive {:conn_status_changed, :ready}

      # The call rode out the race instead of giving up on a client that was on its way. What the
      # graph answers once it gets there is `execute/3`'s business, not this wait's.
      refute match?({:error, :not_started}, Task.await(task, 3_000))
    end
  end

  describe "execute/4 with a connection that has no API versions yet" do
    setup do
      _stop_conn()
      on_exit(&_stop_conn/0)
      :ok
    end

    test "gives up on a client that is up but never picks any up" do
      _put_startup_wait(200)

      # `auto_connect: false` leaves the process and its table up with an empty versions map, so
      # this is the second half of the same start-up: the table is there, but there is still
      # nothing to resolve a request against, and here there never will be.
      assert {:ok, _pid} = _start_conn(auto_connect: false)
      assert {:disconnected, :started} = TestConn.status()

      {elapsed, result} = _measure(fn -> TestConn.execute(:action, _request()) end)

      assert {:error, :not_started} = result
      assert elapsed >= 200
    end

    test "picks up versions that arrive during the grace period" do
      _put_startup_wait(2_000)

      assert {:ok, _pid} = _start_conn(auto_connect: false)

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

  defp _request, do: %Request{path: "capabilities"}

  defp _measure(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp _put_startup_wait(ms) do
    original = Application.fetch_env(:graph_conn, :startup_wait_ms)
    Application.put_env(:graph_conn, :startup_wait_ms, ms)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:graph_conn, :startup_wait_ms, value)
        :error -> Application.delete_env(:graph_conn, :startup_wait_ms)
      end
    end)
  end

  defp _start_conn(config_overrides \\ []) do
    :graph_conn
    |> Application.get_env(TestConn)
    |> Keyword.merge(config_overrides)
    |> TestConn.start_supervisor(%{forward_to: self()})
  end

  # Leaves no client running for `TestConn`, and waits for its table to go with it so the next
  # test doesn't race the teardown.
  defp _stop_conn do
    TestConn
    |> Module.concat(Supervisor)
    |> Process.whereis()
    |> case do
      nil -> :ok
      pid -> Process.exit(pid, :test_cleanup)
    end

    _wait_for_table_gone(System.monotonic_time(:millisecond) + 2_000)
  end

  defp _wait_for_table_gone(deadline) do
    cond do
      :ets.whereis(TestConn) == :undefined ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        _wait_for_table_gone(deadline)

      true ->
        raise "TestConn's table outlived its supervisor"
    end
  end
end
