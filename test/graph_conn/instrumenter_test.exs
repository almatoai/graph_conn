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
      GraphConn.TestClient.stop()
      on_exit(&GraphConn.TestClient.stop/0)
      {:ok, _sup_pid} = GraphConn.TestClient.start()
      assert_receive {:conn_status_changed, :ready}, 15_000

      GraphConn.open_ws_connection(GraphConn.TestConn, :"action-ws")

      assert_receive {[:graph_conn, :ws_upgrade], measurements}, 25_000
      assert %{duration: duration, duration_native: duration_native} = measurements
      assert System.convert_time_unit(duration_native, :native, :millisecond) == duration
    end

    test "carry a native duration on a send, which is where milliseconds run out" do
      # The invoker started in `test_helper.exs` is already connected, so this disturbs no other
      # client's socket. Spawned, because the event fires when the frame goes out -- long before
      # the handler that has to answer it does.
      spawn(fn ->
        ActionInvoker.execute("ExecuteCommand", %{"command" => "ls", "host" => "localhost"})
      end)

      assert_receive {[:graph_conn, :ws_sent_bytes], measurements}, 25_000
      assert %{duration: duration, duration_native: duration_native} = measurements
      assert System.convert_time_unit(duration_native, :native, :millisecond) == duration

      # A send is a local call into the gun process, which is the whole reason the millisecond
      # reading is not enough: this is the measurement that survives at that scale.
      assert duration_native > 0
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
