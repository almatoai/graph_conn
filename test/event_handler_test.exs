defmodule GraphConn.EventHandlerTest do
  use ExUnit.Case, async: false
  alias GraphConn.Test.EventHandler

  # The client is shared with the rest of the suite and the tests below drop its socket, so every
  # test here starts by waiting for one.
  setup do
    _await_events_ws(System.monotonic_time(:millisecond) + 25_000)
  end

  describe "status/0" do
    test "is :ready when ws connection is established" do
      assert :ready = EventHandler.status()
    end
  end

  test "register and subscribe" do
    assert :ok = EventHandler.register()
    assert :ok = EventHandler.subscribe()
  end

  describe "an events-ws connection that drops" do
    test "leaves the client standing instead of taking its subtree down" do
      manager = _manager_pid()
      assert is_pid(manager)

      _kill_events_ws()

      # The drop reaches `on_status_change/3` as `{:disconnected, reason}`. A callback that
      # handles only `:ready` raises here, inside `ConnectionManager`, under `:one_for_all`.
      Process.sleep(500)
      assert Process.alive?(manager)
      assert manager == _manager_pid()

      _await_events_ws(System.monotonic_time(:millisecond) + 25_000)
    end

    test "comes back on its own" do
      _kill_events_ws()

      _await_events_ws(System.monotonic_time(:millisecond) + 25_000)
    end
  end

  defp _manager_pid do
    EventHandler
    |> Module.concat(ConnectionManager)
    |> Process.whereis()
  end

  # The client is shared with the rest of the suite, and the other test here kills the same
  # socket, so the connection has to be back before it can be dropped again.
  defp _kill_events_ws do
    [{_key, conn_pid}] = :ets.lookup(EventHandler, {:"events-ws", :conn_pid})

    Process.exit(conn_pid, :kill)
  end

  defp _await_events_ws(deadline) do
    EventHandler
    |> :ets.lookup({:"events-ws", :conn_pid})
    |> case do
      [{_key, conn_pid}] when is_pid(conn_pid) ->
        :ok

      _not_back_yet ->
        assert System.monotonic_time(:millisecond) < deadline, "events-ws never reopened"
        Process.sleep(50)
        _await_events_ws(deadline)
    end
  end
end
