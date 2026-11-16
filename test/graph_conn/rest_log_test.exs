defmodule GraphConn.RestLogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GraphConn.{Request, TestClient, TestConn}

  setup do
    TestClient.stop()
    on_exit(&TestClient.stop/0)

    assert {:ok, _sup_pid} = TestClient.start()
    assert_receive {:conn_status_changed, :ready}, 5_000

    :ok
  end

  test "logs a REST request's path at debug, but not its query" do
    secret = "s3cret-" <> UUID.uuid4()
    request = %Request{path: "capabilities", query_params: %{"password" => secret}}

    log = capture_log([level: :debug], fn -> TestConn.execute(:action, request) end)

    assert log =~ "[GraphRestCaller] Sending GET: http://localhost:"
    assert log =~ ~r{/capabilities$}m
    refute log =~ secret
  end
end
