defmodule GraphConn.InstrumenterTest do
  @moduledoc """
  The measurements every timed `[:graph_conn, …]` event carries.
  """

  use ExUnit.Case, async: false

  alias GraphConn.Instrumenter

  describe "the timed events" do
    setup context do
      GraphConn.TestClient.stop()
      {:ok, _sup_pid} = GraphConn.TestClient.start()
      on_exit(&GraphConn.TestClient.stop/0)

      events = [[:graph_conn, :rest], [:graph_conn, :ws_upgrade], [:graph_conn, :ws_sent_bytes]]
      test_pid = self()

      :telemetry.attach_many(
        context.test,
        events,
        fn event, measurements, _data, _config -> send(test_pid, {event, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(context.test) end)

      :ok
    end

    test "carry a duration a consumer can read at sub-millisecond resolution" do
      assert_receive {:conn_status_changed, :ready}, 15_000
      GraphConn.TestConn.execute(:action, %GraphConn.Request{path: "capabilities"})

      assert_receive {[:graph_conn, :rest], measurements}, 15_000
      assert %{duration: duration, duration_native: duration_native} = measurements
      assert is_integer(duration)

      # Milliseconds stay the documented unit; native is additive, so a consumer reading either
      # keeps working across a bump.
      assert System.convert_time_unit(duration_native, :native, :millisecond) == duration
    end
  end

  describe "the WebSocket timed events" do
    setup context do
      events = [[:graph_conn, :ws_upgrade], [:graph_conn, :ws_sent_bytes]]
      test_pid = self()

      :telemetry.attach_many(
        context.test,
        events,
        fn event, measurements, _data, _config -> send(test_pid, {event, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(context.test) end)

      :ok
    end

    test "carry a native duration on an upgrade" do
      _start_client()

      GraphConn.open_ws_connection(GraphConn.TestConn, :"action-ws")

      assert_receive {[:graph_conn, :ws_upgrade], measurements}, 25_000
      assert %{duration: duration, duration_native: duration_native} = measurements
      assert System.convert_time_unit(duration_native, :native, :millisecond) == duration
    end

    test "carry a native duration on a send, which is where milliseconds run out" do
      # This client's own socket rather than the standalone invoker `test_helper.exs` shares with
      # every other test: an unacked request on that one is retried for ~9s after this test ends,
      # and a resend consumes a rate-limit arm a later test set for itself.
      _start_client()

      assert :ok =
               GraphConn.TestConn.execute(:"action-ws", %GraphConn.Request{path: "capabilities"})

      assert_receive {[:graph_conn, :ws_sent_bytes], measurements}, 25_000
      assert %{duration: duration, duration_native: duration_native} = measurements
      assert System.convert_time_unit(duration_native, :native, :millisecond) == duration

      # A send is a local call into the gun process, which is the whole reason the millisecond
      # reading is not enough: this is the measurement that survives at that scale.
      assert duration_native > 0
    end
  end

  # A client of this test's own, started only once the previous one's sockets are gone from the
  # mock -- otherwise the next client never reaches `:ready` and a second test in a describe waits
  # for a status change that never arrives. `{:client, _}` is the client-scoped key: the bare
  # `"action_invoker"` routing key is shared with the standalone invoker, which never goes away.
  defp _start_client do
    _await_no_client_sockets("invoker", System.monotonic_time(:millisecond) + 15_000)

    GraphConn.TestClient.stop()
    on_exit(&GraphConn.TestClient.stop/0)
    {:ok, _sup_pid} = GraphConn.TestClient.start()
    assert_receive {:conn_status_changed, :ready}, 15_000
  end

  defp _await_no_client_sockets(client_type, deadline) do
    Registry.TestSockets
    |> Registry.lookup({:client, client_type})
    |> case do
      [] ->
        :ok

      still_registered ->
        assert System.monotonic_time(:millisecond) < deadline,
               "#{client_type} still had #{length(still_registered)} sockets registered"

        Process.sleep(10)
        _await_no_client_sockets(client_type, deadline)
    end
  end

  describe "duration/1" do
    test "agrees with the millisecond measurement the events carry" do
      mono_start = System.monotonic_time() - System.convert_time_unit(120, :millisecond, :native)

      assert Instrumenter.duration(mono_start) ==
               Instrumenter.durations(mono_start).duration
    end
  end

  describe "durations/1" do
    test "reports the same interval in milliseconds and in native units" do
      mono_start = System.monotonic_time() - System.convert_time_unit(250, :millisecond, :native)

      assert %{duration: duration, duration_native: duration_native} =
               Instrumenter.durations(mono_start)

      assert duration in 250..260
      assert System.convert_time_unit(duration_native, :native, :millisecond) in 250..260
    end

    test "keeps sub-millisecond resolution the millisecond measurement cannot express" do
      # `:gun.ws_send/3` is a local call, so this is the normal case for a ws send rather than
      # the tail: the millisecond reading truncates to zero and tells a consumer nothing.
      mono_start = System.monotonic_time() - System.convert_time_unit(150, :microsecond, :native)

      assert %{duration: 0, duration_native: duration_native} =
               Instrumenter.durations(mono_start)

      # The subtraction is exact and overhead only adds, so the floor is guaranteed.
      assert System.convert_time_unit(duration_native, :native, :microsecond) >= 150
    end
  end
end
