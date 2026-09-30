defmodule GraphConn.GunTest do
  use ExUnit.Case, async: true

  test "gun ws connection on local phoenix server" do
    if Process.whereis(GraphConn.Test.MockServer) do
      # This one works in the moment of writing with local mock server.
      connect_opts = %{
        connect_timeout: :timer.minutes(1),
        retry: 10,
        retry_timeout: 10,
        http_opts: %{keepalive: :infinity},
        http2_opts: %{keepalive: :infinity},
        protocols: [:http]
      }

      host = ~c"localhost"
      port = Application.fetch_env!(:graph_conn, :mock_server_port)
      path = ~c"/api/0.9/action-ws/"
      assert {:ok, conn_pid} = :gun.open(host, port, connect_opts)
      assert Process.alive?(conn_pid)
      assert {:ok, _protocol} = :gun.await_up(conn_pid, :timer.minutes(1))

      stream_ref = :gun.ws_upgrade(conn_pid, path, [], %{})

      assert_receive {:gun_upgrade, ^conn_pid, ^stream_ref, ["websocket"], _response_headers}
      refute_receive _, 2_000
    end
  end
end
