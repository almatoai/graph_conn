defmodule GraphConn.VersionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias GraphConn.{TestClient, TestConn}

  describe "version/2 on a client that picked up its versions" do
    setup do
      TestClient.stop()
      on_exit(&TestClient.stop/0)

      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 5_000

      manager = _manager_pid()
      # Tracing ends with the test process, its tracer.
      :erlang.trace(manager, true, [:receive])

      {:ok, manager: manager}
    end

    test "returns the version the graph listed for a known api" do
      assert {:ok, %{path: "/api/0.9/action/", protocol: "", subprotocol: "0.9"}} ==
               GraphConn.version(TestConn, :action)
    end

    test "is reachable through the client module" do
      assert {:ok, %{path: "/api/7.1/graph/", protocol: "", subprotocol: "7.1"}} ==
               TestConn.version(:graph)
    end

    test "asks the manager for nothing when the api is known", %{manager: manager} do
      assert {:ok, _version} = GraphConn.version(TestConn, :action)

      # Every message the manager got before this call is traced by the time it answers.
      _state = :sys.get_state(manager)

      refute_received {:trace, ^manager, :receive, {:"$gen_cast", _request}}
    end

    test "names the known apis and reports the unknown one for a lookup", %{manager: manager} do
      assert {:error, {:unknown_api, apis}} = GraphConn.version(TestConn, :nonexistent)

      assert :action in apis
      refute :nonexistent in apis

      assert_receive {:trace, ^manager, :receive,
                      {:"$gen_cast", {:api_missing, :nonexistent, :execute}}}
    end
  end

  describe "version/2 on a client that is not running" do
    setup do
      TestClient.put_env(:startup_wait_ms, 0)
      :ok
    end

    test "is :not_started" do
      {result, log} = with_log(fn -> GraphConn.version(NeverStarted, :action) end)

      assert {:error, :not_started} == result
      assert log =~ "No connection is ready for NeverStarted"
    end

    test "a version lookup on a client that is not running does not claim to refuse a request" do
      {result, log} = with_log(fn -> GraphConn.version(NeverStarted, :action) end)

      assert {:error, :not_started} == result
      assert log =~ "No connection is ready for NeverStarted, no action version yet."
      refute log =~ "refusing action request"
    end

    test "a request to a client that is not running is still refused in so many words" do
      request = %GraphConn.Request{path: "capabilities"}

      {result, log} = with_log(fn -> GraphConn.execute(NeverStarted, :action, request) end)

      assert {:error, :not_started} == result
      assert log =~ "No connection is ready for NeverStarted, refusing action request."
    end
  end

  defp _manager_pid do
    TestConn
    |> Module.concat(ConnectionManager)
    |> Process.whereis()
  end
end
