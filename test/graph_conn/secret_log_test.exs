defmodule GraphConn.SecretLogTest do
  @moduledoc "Whether a message a callback cannot place ends up in the log with its payload."

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GraphConn.ActionApi.Invoker.State, as: InvokerState
  alias GraphConn.Test.EventHandler
  alias GraphConn.WsConnection

  defmodule BareConn do
    @moduledoc "A client that keeps every default callback."
    use GraphConn, otp_app: :graph_conn
  end

  setup do
    {:ok, secret: "s3cret-" <> UUID.uuid4()}
  end

  describe "a message nobody handles, logged at debug" do
    test "keeps the payload out of GraphConn's default handle_message/3", %{secret: secret} do
      msg = %{"type" => "odd", "id" => "m1", "password" => secret}

      log = _debug_log(fn -> BareConn.handle_message(:"graph-ws", msg, nil) end)

      assert log =~ ~s(Received unhandled message from graph-ws: type="odd" id="m1")
      refute log =~ secret
    end

    test "keeps the payload out of the invoker's unexpected-message log", %{secret: secret} do
      msg = %{"type" => "odd", "id" => "m1", "password" => secret}

      log = _debug_log(fn -> ActionInvoker.handle_message(:"action-ws", msg, %InvokerState{}) end)

      assert log =~ "[ActionInvoker] Received unexpected message"
      refute log =~ secret
    end

    test "keeps the frame out of the invoker's refusal logs, but not the error", %{secret: secret} do
      for code <- [429, 503] do
        msg = %{"error" => %{"code" => code}, "parameters" => %{"password" => secret}}

        log =
          _debug_log(fn -> ActionInvoker.handle_message(:"action-ws", msg, %InvokerState{}) end)

        assert log =~ "no request id: %{\"code\" => #{code}}"
        refute log =~ secret
      end
    end

    test "keeps the payload out of the handler's unexpected-message log", %{secret: secret} do
      msg = %{"type" => "odd", "id" => "m1", "password" => secret}

      log = _debug_log(fn -> TestActionHandler.handle_message(:"action-ws", msg, nil) end)

      assert log =~ "[ActionHandler] Received unexpected message"
      refute log =~ secret
    end

    test "keeps the payload out of the event handler's unexpected-message log", %{secret: secret} do
      msg = %{"type" => "odd", "id" => "m1", "password" => secret}

      log = _debug_log(fn -> EventHandler.handle_message(:"events-ws", msg, nil) end)

      assert log =~ "[EventHandler] Received unexpected message"
      refute log =~ secret
    end

    test "ignores an event the handler does not override, without logging its body",
         %{secret: secret} do
      event = %{"type" => "CREATE", "id" => "e1", "body" => %{"password" => secret}}
      handle = fn -> EventHandler.handle_message(:"events-ws", event, nil) end

      {result, log} = with_log([level: :debug], handle)

      assert {:ok, :ignored} == result
      assert log =~ ~s([EventHandler] Unhandled event message: type="CREATE" id="e1")
      refute log =~ secret
    end
  end

  describe "a WebSocket connection, logged at debug" do
    test "keeps an unexpected message and its own state out of the log", %{secret: secret} do
      state = _ws_state(secret)
      handle = fn -> WsConnection.handle_info({:odd, secret}, state) end

      {result, log} = with_log([level: :debug], handle)

      assert {:noreply, ^state} = result
      assert log =~ "Unexpected message on graph-ws: :odd"
      refute log =~ secret
    end

    test "keeps a refused token answer's payload out of the log", %{secret: secret} do
      state = _ws_state("token-state")
      answer = %{"id" => "t1", "error" => %{"code" => 401}, "_TOKEN" => secret}
      handle = fn -> WsConnection.handle_info({:token_answered, "t1", answer}, state) end

      log = _debug_log(handle)

      assert log =~ ~s(refused the refreshed token: type=nil id="t1" error=%{"code" => 401})
      refute log =~ secret
    end
  end

  defp _debug_log(fun),
    do: capture_log([level: :debug], fun)

  defp _ws_state(secret) do
    %WsConnection.State{
      base_name: BareConn,
      api: :"graph-ws",
      internal_state: %{token: secret},
      status: :ready,
      last_pong: DateTime.utc_now(),
      ws_ping: []
    }
  end
end
