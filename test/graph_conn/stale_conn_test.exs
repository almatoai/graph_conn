defmodule GraphConn.StaleConnTest do
  use ExUnit.Case, async: false

  alias GraphConn.{GraphRestCalls, TestClient, TestConn}
  alias GraphConn.Test.DropProxy

  setup do
    original = Application.get_env(:graph_conn, :conn_max_idle_time)

    {:ok, proxy} =
      :graph_conn
      |> Application.fetch_env!(:mock_server_port)
      |> DropProxy.start_link()

    on_exit(fn ->
      original
      |> case do
        nil -> Application.delete_env(:graph_conn, :conn_max_idle_time)
        val -> Application.put_env(:graph_conn, :conn_max_idle_time, val)
      end

      TestClient.stop()
    end)

    {:ok, proxy: proxy}
  end

  test "a silently dropped conn kept with conn_max_idle_time :infinity fails the next auth",
       %{proxy: proxy} do
    Application.put_env(:graph_conn, :conn_max_idle_time, :infinity)
    {config, versions} = _start_through(proxy)

    :ok = DropProxy.drop(proxy)

    assert {:error, :closed} == GraphRestCalls.authenticate(TestConn, config, versions)
    assert 1 == DropProxy.resets(proxy)
  end

  test "a conn idle past conn_max_idle_time is replaced before it is written to",
       %{proxy: proxy} do
    Application.put_env(:graph_conn, :conn_max_idle_time, 50)
    {config, versions} = _start_through(proxy)

    :ok = DropProxy.drop(proxy)
    Process.sleep(100)

    assert {:ok, %{token: _token, expires_at: _expires_at}} =
             GraphRestCalls.authenticate(TestConn, config, versions)

    assert 0 == DropProxy.resets(proxy)
  end

  # Authenticating on the way to `:ready` leaves the pool holding a conn through the proxy.
  defp _start_through(proxy) do
    {:ok, _supervisor} = TestClient.start(url: "http://localhost:#{DropProxy.port(proxy)}")

    assert_receive {:conn_status_changed, :ready}

    [{:config, config}] = :ets.lookup(TestConn, :config)
    [{:versions, versions}] = :ets.lookup(TestConn, :versions)
    {config, versions}
  end
end
