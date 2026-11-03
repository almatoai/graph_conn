defmodule GraphConn.WSTest do
  use ExUnit.Case, async: true
  import GraphConn.WS
  import ExUnit.CaptureLog

  describe "connect/3" do
    test "returns connection pid and api versions on success" do
      logged = fn -> _assert_connects(:http2) end
      assert capture_log(logged) =~ ~r/Connected to .* using http2/
    end

    test "connection can be forced for HTTP1.1" do
      logged = fn -> _assert_connects(:http) end
      assert capture_log(logged) =~ ~r/Connected to .* using http/
    end
  end

  defp _config do
    :graph_conn
    |> Application.get_env(GraphConn.TestConn)
    |> GraphConn.ConnectionManager.parse_urls()
  end

  defp _assert_connects(protocol) do
    config = _config()
    host = Keyword.fetch!(config, :host)
    port = Keyword.fetch!(config, :port)

    assert {:ok, conn_pid, nil} = connect(host, port, [{:protocols, [protocol]} | config])
    assert Process.alive?(conn_pid)
  end
end
