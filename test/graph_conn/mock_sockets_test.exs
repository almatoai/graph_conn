defmodule GraphConn.MockSocketsTest do
  use ExUnit.Case, async: false

  alias GraphConn.MockSockets

  @client_type "mock_sockets_test"

  describe "await_new/3" do
    test "returns the socket registered after the snapshot, not one an earlier test left" do
      stale = _register_socket()
      known_sockets = MockSockets.registered(@client_type)
      assert stale in known_sockets

      deadline = System.monotonic_time(:millisecond) + 5_000
      task = Task.async(fn -> MockSockets.await_new(@client_type, known_sockets, deadline) end)
      fresh = _register_socket()

      assert fresh == Task.await(task)
    end

    test "fails the test when no new socket registers before the deadline" do
      _stale = _register_socket()
      known_sockets = MockSockets.registered(@client_type)
      deadline = System.monotonic_time(:millisecond)

      assert_raise ExUnit.AssertionError, ~r/never registered/, fn ->
        MockSockets.await_new(@client_type, known_sockets, deadline)
      end
    end
  end

  # Stands in for the mock's side of a socket: registered under the client key until the test ends.
  defp _register_socket do
    test_pid = self()

    hold_registration = fn ->
      {:ok, _owner} = Registry.register(Registry.TestSockets, {:client, @client_type}, {})
      send(test_pid, {:registered, self()})

      receive do
        :never -> :ok
      end
    end

    socket = spawn_link(hold_registration)

    assert_receive {:registered, ^socket}
    socket
  end
end
