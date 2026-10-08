defmodule GraphConn.RetokenTest do
  use ExUnit.Case, async: false

  alias GraphConn.{Mock, Request, TestClient, TestConn}

  # TestConn authenticates with these credentials; rotating them tells a refreshed token apart.
  @base_token "action_invoker"

  setup do
    TestClient.stop()
    Mock.rotate_tokens(@base_token, true)

    on_exit(fn ->
      TestClient.stop()
      Mock.rotate_tokens(@base_token, false)
      Mock.delay_ws_upgrade("invoker", 0)
    end)

    assert {:ok, _sup_pid} = TestClient.start()
    assert_receive {:conn_status_changed, :ready}, 15_000
    GraphConn.open_ws_connection(TestConn, :"action-ws")
    assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000

    {:ok, ws_connection: _ws_connection(), old_token: _current_token()}
  end

  describe "action-ws, which has no token message" do
    test "is reopened with the refreshed token", %{ws_connection: old, old_token: old_token} do
      assert :ok = GenServer.call(_manager_pid(), :refresh_token)

      new_token = _current_token()
      assert new_token != old_token
      assert :ok = _await_upgrade_with(new_token, _deadline())

      new = _ws_connection()
      assert is_pid(new)
      assert new != old
      assert Process.alive?(new)
      refute Process.alive?(old)
    end

    test "the replaced socket's exit does not reopen it a second time", %{ws_connection: old} do
      old_monitor = Process.monitor(old)
      assert :ok = GenServer.call(_manager_pid(), :refresh_token)
      assert_receive {:DOWN, ^old_monitor, :process, ^old, _reason}
      assert_receive {:conn_status_changed, :"action-ws", :ready}
      new = _ws_connection()

      # Past the first step of the reconnect curve, where a reopen off the old socket would land.
      refute_receive {:conn_status_changed, _api, _status}, 3_000
      assert new == _ws_connection()
    end

    test "a socket that does not stop in time is killed, so the refresh still replaces it",
         %{ws_connection: old} do
      Application.put_env(:graph_conn, :ws_stop_timeout_ms, 200)
      on_exit(fn -> Application.delete_env(:graph_conn, :ws_stop_timeout_ms) end)

      # Busy inside a system message, it cannot act on the stop until the stop has timed out.
      spawn(fn -> :sys.replace_state(old, &_stall/1, :infinity) end)

      assert :ok = _await_stuck(old, _deadline())
      assert :ok = GenServer.call(_manager_pid(), :refresh_token, 10_000)

      refute Process.alive?(old)
      new = _ws_connection()
      assert is_pid(new)
      assert new != old
    end

    test "a caller that arrives during a slow reopen waits for it rather than failing" do
      # Longer than `:startup_wait_ms`, the whole wait a caller gets when no reopen is on the clock.
      Mock.delay_ws_upgrade("invoker", 800)

      # A frame the mock takes silently, so the ack proves it went through the reopened socket.
      frame_id = UUID.uuid4()

      caller =
        Task.async(fn ->
          Process.sleep(100)

          TestConn.execute(:"action-ws", %Request{body: %{type: "acknowledged", id: frame_id}})
        end)

      assert :ok = GenServer.call(_manager_pid(), :refresh_token, 10_000)
      assert :ok == Task.await(caller, 15_000)
      assert :ok == _await_acknowledged(frame_id, _deadline())
    end
  end

  describe "a socket that takes a token message" do
    for api <- [:"events-ws", :"graph-ws"] do
      @api api

      test "#{api} is sent the refreshed token instead of being reopened" do
        GraphConn.open_ws_connection(TestConn, @api)
        assert_receive {:conn_status_changed, @api, :ready}, 15_000
        socket = _ws_connection(@api)
        upgrade_token = _current_token()

        assert :ok = GenServer.call(_manager_pid(), :refresh_token)

        new_token = _current_token()
        assert new_token != upgrade_token
        assert :ok = _await_token_update(@api, upgrade_token, [new_token], _deadline())
        assert socket == _ws_connection(@api)
        refute_receive {:conn_status_changed, @api, _status}, 500
      end
    end

    test "graph-ws's answer to the token message never reaches the consumer" do
      GraphConn.open_ws_connection(TestConn, :"graph-ws")
      assert_receive {:conn_status_changed, :"graph-ws", :ready}, 15_000
      upgrade_token = _current_token()

      assert :ok = GenServer.call(_manager_pid(), :refresh_token)
      new_token = _current_token()
      assert :ok = _await_token_update(:"graph-ws", upgrade_token, [new_token], _deadline())

      refute_receive {:received_message, :"graph-ws", _msg}, 1_000
    end
  end

  defp _deadline,
    do: System.monotonic_time(:millisecond) + 5_000

  # The mock records an upgrade once the socket is up on its side, a moment after the client's.
  defp _await_upgrade_with(token, deadline) do
    cond do
      token in Mock.ws_upgrades(:"action-ws") ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("action-ws was never upgraded with the refreshed token")

      true ->
        Process.sleep(20)
        _await_upgrade_with(token, deadline)
    end
  end

  defp _await_acknowledged(frame_id, deadline) do
    cond do
      Mock.acknowledged?(frame_id) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the frame sent through the reopened socket never reached the mock")

      true ->
        Process.sleep(20)
        _await_acknowledged(frame_id, deadline)
    end
  end

  defp _stall(ws_state) do
    Process.sleep(:infinity)
    ws_state
  end

  defp _await_stuck(pid, deadline) do
    cond do
      {:current_function, {Process, :sleep, 1}} == Process.info(pid, :current_function) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the socket never got stuck")

      true ->
        Process.sleep(10)
        _await_stuck(pid, deadline)
    end
  end

  defp _current_token do
    [{:token, token}] = :ets.lookup(TestConn, :token)
    token
  end

  defp _await_token_update(api, upgrade_token, expected, deadline) do
    cond do
      expected == Mock.token_updates(api, upgrade_token) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("#{api} was never sent the refreshed token")

      true ->
        Process.sleep(20)
        _await_token_update(api, upgrade_token, expected, deadline)
    end
  end

  defp _ws_connection(api \\ :"action-ws") do
    TestConn
    |> :ets.lookup({api, :conn_pid})
    |> case do
      [{_key, pid}] -> pid
      [] -> nil
    end
  end

  defp _manager_pid do
    TestConn
    |> Module.concat("ConnectionManager")
    |> Process.whereis()
  end
end
