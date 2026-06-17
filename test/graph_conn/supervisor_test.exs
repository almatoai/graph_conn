defmodule GraphConn.SupervisorTest do
  use ExUnit.Case, async: false

  alias GraphConn.{Request, TestConn}

  describe "Finch conn_max_idle_time" do
    setup do
      original = Application.get_env(:graph_conn, :conn_max_idle_time)
      test_pid = self()

      "supervisor-test-idle-#{inspect(self())}"
      |> :telemetry.attach(
        [:finch, :conn_max_idle_time_exceeded],
        fn _, _, _, _ -> send(test_pid, :idle_exceeded) end,
        nil
      )

      fn ->
        :telemetry.detach("supervisor-test-idle-#{inspect(test_pid)}")

        original
        |> case do
          nil -> Application.delete_env(:graph_conn, :conn_max_idle_time)
          val -> Application.put_env(:graph_conn, :conn_max_idle_time, val)
        end

        TestConn
        |> Module.concat(Supervisor)
        |> Process.whereis()
        |> case do
          nil -> :ok
          pid -> Process.exit(pid, :test_cleanup)
        end
      end
      |> on_exit()

      :ok
    end

    test "idle connection is discarded when conn_max_idle_time is configured" do
      Application.put_env(:graph_conn, :conn_max_idle_time, 50)

      config = Application.get_env(:graph_conn, TestConn)
      assert {:ok, _pid} = _start_connection(config)
      assert_receive {:conn_status_changed, :ready}

      # Wait longer than the configured idle time so the connection ages
      Process.sleep(100)

      # Trigger a checkout — Finch discards the stale connection and emits the event
      assert {:ok, _} = TestConn.execute(:action, %Request{path: "capabilities"})

      assert_receive :idle_exceeded, 500
      assert :ok = TestConn.stop()
    end

    test "idle connection is kept when conn_max_idle_time is not configured" do
      Application.delete_env(:graph_conn, :conn_max_idle_time)

      config = Application.get_env(:graph_conn, TestConn)
      assert {:ok, _pid} = _start_connection(config)
      assert_receive {:conn_status_changed, :ready}

      Process.sleep(100)

      assert {:ok, _} = TestConn.execute(:action, %Request{path: "capabilities"})

      refute_receive :idle_exceeded, 200
      assert :ok = TestConn.stop()
    end
  end

  defp _start_connection(config) do
    config
    |> TestConn.start_supervisor(%{forward_to: self()})
    |> case do
      {:ok, pid} ->
        assert Process.alive?(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Process.exit(pid, :we_need_new_connection)
        _start_connection(config)
    end
  end
end
