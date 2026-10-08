defmodule GraphConn.Test.MockSocketTest do
  use ExUnit.Case, async: false

  alias GraphConn.{Request, TestClient, TestConn}

  setup do
    on_exit(fn ->
      TestClient.stop()
    end)

    :ok
  end

  describe "an invalid action-ws frame" do
    test "is answered with a 400 to the sending socket only, not to the rest of its role" do
      # Stands in for a second socket playing the invoker role, as the routing registry sees it.
      {:ok, _owner} = Registry.register(Registry.TestSockets, "action_invoker", {})

      {:ok, _supervisor} = TestClient.start()

      assert_receive {:conn_status_changed, :ready}

      assert :ok = TestConn.execute(:"action-ws", %Request{body: %{fake_message: "Hello"}})

      assert_receive {:received_message, :"action-ws",
                      %{
                        "code" => 400,
                        "message" => "invalid action message" <> _,
                        "type" => "error"
                      }}

      refute_receive "{\"code\":400" <> _not_mine, 500
    end
  end

  describe "an invalid events-ws frame" do
    test "is answered with a 400 to the sending socket only, not to the rest of its key" do
      {:ok, _supervisor} = TestClient.start()

      assert_receive {:conn_status_changed, :ready}
      :ok = GraphConn.open_ws_connection(TestConn, :"events-ws")
      assert_receive {:conn_status_changed, :"events-ws", :ready}

      # Stands in for a second socket sharing this one's routing key, which other clients may too.
      :ok = _await_registered(_events_key(), System.monotonic_time(:millisecond) + 5_000)
      {:ok, _owner} = Registry.register(Registry.TestSockets, _events_key(), {})

      assert :ok = TestConn.execute(:"events-ws", %Request{body: %{fake_message: "Hello"}})

      assert_receive {:received_message, :"events-ws",
                      %{"code" => 400, "message" => "invalid event message" <> _}}

      refute_receive "{\"code\":400" <> _not_mine, 500
    end
  end

  # The client sees the upgrade before the mock's socket has registered itself.
  defp _await_registered(key, deadline) do
    Registry.TestSockets
    |> Registry.lookup(key)
    |> case do
      [_socket | _others] ->
        :ok

      [] ->
        assert System.monotonic_time(:millisecond) < deadline, "no mock socket under #{key}"
        Process.sleep(10)
        _await_registered(key, deadline)
    end
  end

  defp _events_key do
    [{:versions, %{"events-ws": %{path: path}}}] = :ets.lookup(TestConn, :versions)
    path
  end
end
