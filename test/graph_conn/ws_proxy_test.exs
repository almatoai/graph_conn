defmodule GraphConn.WSProxyTest do
  @moduledoc """
  Reaching the graph through a client's HTTP proxy, which is how on-prem action handlers connect.
  """

  use ExUnit.Case, async: false

  @moduletag :proxy

  alias GraphConn.{Mock, WS}
  alias GraphConn.Test.ProxyFixture

  # squid resolves this to the host running the mock server; see docker-compose.test.yaml.
  @graph_host "host.docker.internal"
  @graph_port 8081
  @path ~c"/api/0.9/action-ws/"
  @subprotocol "0.9"
  # Its own client type, so an arm here cannot deny a client another test is using.
  @token "action_proxy"
  # What `ConnectionManager` derives for an `http://` graph url.
  @connect_opts [transport: :tcp, protocols: [:http], insecure: true]

  setup do
    original = Application.get_env(:graph_conn, :proxy)

    Application.put_env(:graph_conn, :proxy,
      address: "localhost",
      port: to_string(ProxyFixture.port()),
      transport: "tcp",
      insecure: "true"
    )

    on_exit(fn ->
      Mock.clear_rate_limit({:ws_upgrade, "proxy"})

      if original,
        do: Application.put_env(:graph_conn, :proxy, original),
        else: Application.delete_env(:graph_conn, :proxy)
    end)

    :ok
  end

  describe "connect/3 through a proxy" do
    test "tunnels to the graph and reports the tunnel it opened" do
      assert {:ok, conn_pid, tunnel_ref} = WS.connect(@graph_host, @graph_port, @connect_opts)
      assert Process.alive?(conn_pid)
      assert is_reference(tunnel_ref)
    end
  end

  describe "ws_upgrade/5 through a proxy" do
    test "opens the stream inside the tunnel rather than on the proxy connection" do
      {:ok, conn_pid, tunnel_ref} = WS.connect(@graph_host, @graph_port, @connect_opts)

      assert {:ok, stream_ref} =
               WS.ws_upgrade(conn_pid, @path, @subprotocol, @token, tunnel_ref)

      # gun names a tunnelled stream by the tunnel it runs in. Upgrading without naming the
      # tunnel leaves a bare reference here, and gun crashes trying to split it.
      assert [^tunnel_ref, ws_ref] = stream_ref
      assert is_reference(ws_ref)
    end

    test "carries frames on the tunnelled stream" do
      {:ok, conn_pid, tunnel_ref} = WS.connect(@graph_host, @graph_port, @connect_opts)
      {:ok, stream_ref} = WS.ws_upgrade(conn_pid, @path, @subprotocol, @token, tunnel_ref)

      assert :ok == WS.ping(conn_pid, stream_ref)
    end

    test "surfaces a 429 as a rate limit rather than timing out" do
      Mock.reject_ws_upgrade("proxy", 1, 429, 2)

      {:ok, conn_pid, tunnel_ref} = WS.connect(@graph_host, @graph_port, @connect_opts)

      assert {:error, {:rate_limited, retry_after_ms}} =
               WS.ws_upgrade(conn_pid, @path, @subprotocol, @token, tunnel_ref)

      assert retry_after_ms > 1_000
    end
  end
end
