defmodule GraphConn.WSTest do
  use ExUnit.Case, async: true
  import GraphConn.WS
  import ExUnit.CaptureLog

  describe "connect/3" do
    test "returns connection pid and api versions on success" do
      assert capture_log(fn ->
               assert {:ok, conn_pid} =
                        connect(_host(), _port(), [{:protocols, [:http2]} | _config()])

               assert Process.alive?(conn_pid)
             end) =~ ~r/Connected to .* using http2/
    end

    test "connection can be forced for HTTP1.1" do
      assert capture_log(fn ->
               assert {:ok, conn_pid} =
                        connect(_host(), _port(), [{:protocols, [:http]} | _config()])

               assert Process.alive?(conn_pid)
             end) =~ ~r/Connected to .* using http/
    end
  end

  defp _config() do
    :graph_conn
    |> Application.get_env(GraphConn.TestConn)
    |> GraphConn.ConnectionManager.parse_urls()
  end

  defp _host, do: Keyword.fetch!(_config(), :host)
  defp _port, do: Keyword.fetch!(_config(), :port)
end
