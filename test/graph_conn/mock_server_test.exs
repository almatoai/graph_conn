defmodule GraphConn.Test.MockServerTest do
  use ExUnit.Case, async: true

  alias GraphConn.Test.MockServer

  describe "waiting for a free port" do
    test "takes a port whose last connection is still in TIME_WAIT, as Ranch would" do
      port = _port_left_in_time_wait()

      assert :ok == MockServer.__await_free_port__(port, 1)
    end

    test "still refuses a port another suite is listening on" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, :eaddrinuse} == MockServer.__await_free_port__(port, 1)
    end
  end

  # Closing the accepted side first leaves the listening port's end in TIME_WAIT.
  defp _port_left_in_time_wait do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
    {:ok, port} = :inet.port(listener)
    {:ok, client} = :gen_tcp.connect(~c"localhost", port, [:binary, {:active, false}])
    {:ok, accepted} = :gen_tcp.accept(listener)

    :ok = :gen_tcp.close(accepted)
    {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)
    :ok = :gen_tcp.close(client)
    :ok = :gen_tcp.close(listener)

    assert {:error, :eaddrinuse} == :gen_tcp.listen(port, [:binary, {:active, false}])
    port
  end
end
