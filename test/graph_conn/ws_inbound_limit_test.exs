defmodule GraphConn.WsInboundLimitTest do
  use ExUnit.Case, async: false

  alias GraphConn.{TestClient, TestConn}

  setup do
    TestClient.stop()
    on_exit(&TestClient.stop/0)
    :ok
  end

  test "takes a frame from the server above gun's own 1_000_000 default" do
    _start_with_action_ws([])
    data = String.duplicate("a", 1_500_000)

    _send_from_server(%{type: "bigMessage", data: data})

    assert_receive {:received_message, :"action-ws", %{"type" => "bigMessage", "data" => ^data}},
                   5_000
  end

  test "drops the socket on a frame above its configured :ws_max_frame_bytes" do
    ws_connection = _start_with_action_ws(ws_max_frame_bytes: 1_000)
    monitor = Process.monitor(ws_connection)

    _send_from_server(%{type: "bigMessage", data: String.duplicate("a", 2_000)})

    # gun closes an oversized frame's socket as a close frame with no reason text.
    assert_receive {:DOWN, ^monitor, :process, ^ws_connection, "server sent close request: "},
                   5_000

    refute_received {:received_message, :"action-ws", %{"type" => "bigMessage"}}
  end

  for bad <- [0, -1, "16MB", nil] do
    @bad bad

    test "a :ws_max_frame_bytes of #{inspect(bad)} refuses to start the client" do
      Process.flag(:trap_exit, true)

      assert {:error,
              {:shutdown,
               {:failed_to_start_child, GraphConn.ConnectionManager,
                {%ArgumentError{message: ":ws_max_frame_bytes must be" <> _rest}, _stack}}}} =
               TestClient.start(ws_max_frame_bytes: @bad)
    end
  end

  defp _start_with_action_ws(config_overrides) do
    assert {:ok, _sup_pid} = TestClient.start(config_overrides)
    assert_receive {:conn_status_changed, :ready}, 15_000
    GraphConn.open_ws_connection(TestConn, :"action-ws")
    assert_receive {:conn_status_changed, :"action-ws", :ready}, 15_000
    assert :ok = _await_mock_socket(System.monotonic_time(:millisecond) + 5_000)

    [{_key, ws_connection}] = :ets.lookup(TestConn, {:"action-ws", :conn_pid})
    ws_connection
  end

  defp _send_from_server(message) do
    frame = Jason.encode!(message)

    Registry.TestSockets
    |> Registry.dispatch({:client, "invoker"}, fn entries ->
      for {pid, _value} <- entries, do: send(pid, frame)
    end)
  end

  # The mock registers its side of the socket a moment after the client sees the upgrade.
  defp _await_mock_socket(deadline) do
    cond do
      [] != Registry.lookup(Registry.TestSockets, {:client, "invoker"}) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the mock never registered the socket")

      true ->
        Process.sleep(10)
        _await_mock_socket(deadline)
    end
  end
end
