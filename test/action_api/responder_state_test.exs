defmodule GraphConn.ActionApi.ResponderStateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GraphConn.ActionApi.Responder

  test "keeps a pending response out of the Responder's crash report" do
    secret = "s3cret-" <> UUID.uuid4()
    base_name = :"responder_state_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start(Responder, base_name, name: Responder.name(base_name))
    ref = Process.monitor(pid)
    response = %GraphConn.Request{body: %{id: "r1", type: "sendActionResult", result: secret}}
    GenServer.cast(pid, {:register_response, response, 60_000})

    crash = fn ->
      catch_exit(GenServer.call(pid, :stray))
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    log = capture_log([level: :debug], crash)

    assert log =~ "terminating"
    assert log =~ ~s(pending_responses: ["r1"])
    refute log =~ secret
  end

  test "keeps the response it was handling out of the Responder's crash report" do
    secret = "s3cret-" <> UUID.uuid4()
    base_name = :"responder_state_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start(Responder, base_name, name: Responder.name(base_name))
    ref = Process.monitor(pid)
    response = %GraphConn.Request{body: %{id: "r1", type: "sendActionResult", result: secret}}

    # A negative interval makes `Process.send_after/3` raise while this message is handled.
    crash = fn ->
      GenServer.cast(pid, {:register_response, response, -1})
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    log = capture_log([level: :debug], crash)

    assert log =~ ~s(Last message: {:"$gen_cast", {:register_response, "r1", -1}})
    refute log =~ secret
  end
end
