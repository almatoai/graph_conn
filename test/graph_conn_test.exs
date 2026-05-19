defmodule GraphConnTest do
  use ExUnit.Case, async: false
  alias GraphConn.{Request, Response}
  alias GraphConn.TestConn
  import ExUnit.CaptureLog

  describe "connection" do
    test "accepts configuration and establishes connection" do
      config = Application.get_env(:graph_conn, TestConn)
      assert {:ok, pid} = _start_connection(config)
      assert_receive {:conn_status_changed, :ready}
      assert :ready = TestConn.status()

      assert :ok = TestConn.stop()
      refute Process.alive?(pid)
    end

    test "exits on authentication error" do
      Process.flag(:trap_exit, true)
      config = Application.get_env(:graph_conn, TestConn)

      credentials =
        config[:auth][:credentials]
        |> Keyword.put(:password, "wrong")

      auth_config = Keyword.put(config[:auth], :credentials, credentials)
      config = Keyword.put(config, :auth, auth_config)

      assert capture_log(fn ->
               assert {:ok, pid} = _start_connection(config)
               assert_receive {:EXIT, ^pid, :shutdown}
             end) =~ ~r/\(stop\) \:wrong_credentials/
    end

    test "can just get versions with no credentials in config" do
      config =
        :graph_conn
        |> Application.get_env(TestConn)
        |> Keyword.delete(:auth)
        |> Keyword.put(:auto_connect, :just_versions)

      assert {:ok, pid} = _start_connection(config)
      assert_receive {:conn_status_changed, :got_api_versions}
      refute_receive {:conn_status_changed, :ready}
      assert :got_api_versions = TestConn.status()

      assert :ok = TestConn.stop()
      refute Process.alive?(pid)
    end

    test "can just start process without trying to get versions" do
      config =
        :graph_conn
        |> Application.get_env(TestConn)
        |> Keyword.put(:auto_connect, false)

      assert {:ok, pid} = _start_connection(config)
      refute_receive {:conn_status_changed, :got_api_versions}
      refute_receive {:conn_status_changed, :ready}
      assert {:disconnected, :started} = TestConn.status()

      assert :ok = TestConn.stop()
      refute Process.alive?(pid)
    end
  end

  describe "execute/2" do
    setup do
      :graph_conn
      |> Application.get_env(TestConn)
      |> _start_connection()

      assert_receive {:conn_status_changed, :ready}
      assert :ready = TestConn.status()

      :ok
    end

    test "for unknown api returns error and list of available apis" do
      assert {:error, {:unknown_api, known_apis}} = TestConn.execute(:unknown_api, %Request{})
      assert Enum.member?(known_apis, :action)
    end

    test "can invoke REST GET call on `action` API" do
      request = %Request{
        path: "capabilities"
      }

      assert {:ok, %Response{body: %{}}} = TestConn.execute(:action, request)
    end

    test "does not duplicate authorization header when request already has one with different casing" do
      request = %Request{
        path: "test-only/headers",
        headers: %{"authorization" => "Bearer override_token"}
      }

      assert {:ok, %Response{body: body}} = TestConn.execute(:action, request)
      assert ["Bearer override_token"] == body["authorization"]
    end

    test "refreshes token and retries call if token is expired" do
      true = :ets.insert(TestConn, {:token, "wrong_token"})

      request = %Request{
        path: "app/some_dummy_config/handlers"
      }

      assert {:ok, %Response{body: [%{}]}} = TestConn.execute(:action, request)

      # Assert that token has been refreshed
      assert [{:token, "action_invoker"}] == :ets.lookup(TestConn, :token)
    end

    test "doesn't refresh token and retry call if on behalf auth is used" do
      # Setting the token to an invalid value is per-se not relevant, but we need to make sure
      # that no refresh is performed.
      :ets.insert(TestConn, {:token, "token_wont_be_refreshed"})

      request = %Request{
        path: "app/some_dummy_config/handlers",
        headers: %{authorization: "wrong_token"}
      }

      # Assert that this doesn't cause infinite loop and returns the correct response
      assert {:ok, %Response{code: 401}} = TestConn.execute(:action, request)

      # Assert that token has *not* been refreshed
      assert [{:token, "token_wont_be_refreshed"}] == :ets.lookup(TestConn, :token)
    end

    test "opens ws connection on demand" do
      request = %Request{
        body: %{fake_message: "Hello"}
      }

      assert :ok = TestConn.execute(:"action-ws", request)
      assert_receive {:conn_status_changed, :"action-ws", :ready}

      assert_receive {:received_message, :"action-ws",
                      %{
                        "code" => 400,
                        "message" => "invalid action message" <> _,
                        "type" => "error"
                      }}

      # uses existing connection
      assert :ok = TestConn.execute(:"action-ws", request)
      refute_receive {:conn_status_changed, :"action-ws", :ready}, 1_000

      assert_receive {:received_message, :"action-ws",
                      %{
                        "code" => 400,
                        "message" => "invalid action message" <> _,
                        "type" => "error"
                      }}
    end

    test "restarts ws connection when it goes down" do
      # open ws connection
      test_api = :"action-ws"
      assert :ok = TestConn.execute(test_api, %Request{})

      assert_receive {:conn_status_changed, ^test_api, :ready}

      assert_receive {:received_message, ^test_api,
                      %{
                        "code" => 400,
                        "message" => "invalid action message" <> _,
                        "type" => "error"
                      }}

      # find :gun conn_pid
      [{_, ws_connection, _, _}] =
        TestConn.WsConnections
        |> Process.whereis()
        |> Supervisor.which_children()

      %{conn_pid: gun_conn_pid} = :sys.get_state(ws_connection)
      assert Process.alive?(gun_conn_pid)

      # kill gun connection
      Process.exit(gun_conn_pid, :test_wants_you_dead)

      assert_receive {:conn_status_changed, test_api, {:disconnected, :test_wants_you_dead}}

      refute Process.alive?(gun_conn_pid)

      # make sure that connection is back
      # assert_receive {:conn_status_changed, test_api, :ready}

      assert :ok = TestConn.execute(test_api, %Request{})

      assert_receive {:received_message, ^test_api,
                      %{
                        "code" => 400,
                        "message" => "invalid action message" <> _,
                        "type" => "error"
                      }}
    end

    test "ws message is silently resent when connection is dropped" do
      # open ws connection
      assert :ok = TestConn.execute(:"action-ws", %Request{})

      assert_receive {:conn_status_changed, :"action-ws", :ready}

      assert_receive {:received_message, :"action-ws",
                      %{
                        "code" => 400,
                        "message" => "invalid action message" <> _,
                        "type" => "error"
                      }}

      # find and kill :gun conn_pid
      [{_, ws_connection, _, _}] =
        TestConn.WsConnections
        |> Process.whereis()
        |> Supervisor.which_children()

      %{conn_pid: gun_conn_pid} = :sys.get_state(ws_connection)
      Process.exit(gun_conn_pid, :test_wants_you_dead)

      assert_receive {:conn_status_changed, :"action-ws", {:disconnected, :test_wants_you_dead}}

      refute Process.alive?(gun_conn_pid)

      # send message while process is down
      assert capture_log(fn ->
               :ok = TestConn.execute(:"action-ws", %Request{})
             end) =~ ~r/WS connection is down! Retrying message sending.../

      assert_receive {:conn_status_changed, :"action-ws", :ready}

      assert_receive {:received_message, :"action-ws",
                      %{
                        "code" => 400,
                        "message" => "invalid action message" <> _,
                        "type" => "error"
                      }}
    end
  end

  # it takes some time for pid to die, so we need to retry
  defp _start_connection(config) do
    case TestConn.start_supervisor(config, %{forward_to: self()}) do
      {:ok, pid} ->
        assert Process.alive?(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Process.exit(pid, :we_need_new_connection)
        _start_connection(config)
    end
  end
end
