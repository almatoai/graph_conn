defmodule GraphConn.ActionApi.ResponderResendTest do
  use ExUnit.Case, async: false

  alias GraphConn.ActionApi.Responder
  alias GraphConn.Request

  @base ResponderResendTest
  @resend_after 3_000
  # How far below `@resend_after` a timer read right after arming may already have run down.
  @read_slack 200

  setup do
    # No client runs under `@base`, so each resend fails at once instead of waiting for one.
    previous = Application.get_env(:graph_conn, :startup_wait_ms)
    Application.put_env(:graph_conn, :startup_wait_ms, 0)

    restore = fn ->
      if previous,
        do: Application.put_env(:graph_conn, :startup_wait_ms, previous),
        else: Application.delete_env(:graph_conn, :startup_wait_ms)
    end

    on_exit(restore)

    %{pid: start_supervised!({Responder, @base})}
  end

  test "an unacked response is resent at the same interval every time", %{pid: pid} do
    req_id = _register(pid)

    armed_delays = _fire_resends(pid, req_id, 10)

    assert 10 == length(armed_delays)

    for armed <- armed_delays,
        do: assert(armed in (@resend_after - @read_slack)..@resend_after)
  end

  test "an unacked response is still held for resend after many resends", %{pid: pid} do
    req_id = _register(pid)

    _armed_delays = _fire_resends(pid, req_id, 20)

    assert %{responses: %{^req_id => {%Request{body: %{id: ^req_id}}, ref}}} = :sys.get_state(pid)
    remaining = Process.read_timer(ref)
    assert is_integer(remaining)
  end

  test "an ack after resends cancels the pending resend", %{pid: pid} do
    req_id = _register(pid)
    _armed_delays = _fire_resends(pid, req_id, 3)
    %{responses: %{^req_id => {_response, ref}}} = :sys.get_state(pid)

    Responder.response_acked(@base, req_id)

    assert %{responses: responses} = :sys.get_state(pid)
    refute Map.has_key?(responses, req_id)
    refute Process.read_timer(ref)
  end

  describe "return_response/3 with a non-positive resend interval" do
    test "raises naming the callback, and registers nothing", %{pid: pid} do
      for resend_after <- [0, -1] do
        request = %Request{
          body: %{id: "resend-invalid-#{resend_after}", type: "sendActionResult"}
        }

        error =
          assert_raise ArgumentError, fn ->
            Responder.return_response(request, @base, resend_after)
          end

        assert error.message =~ "resend_response_timeout/0"
        assert error.message =~ inspect(resend_after)
      end

      assert %{responses: responses} = :sys.get_state(pid)
      assert 0 == map_size(responses)
    end
  end

  defp _register(pid) do
    req_id = "resend-#{System.unique_integer([:positive])}"
    request = %Request{body: %{id: req_id, type: "sendActionResult", result: "{}"}}
    GenServer.cast(pid, {:register_response, request, @resend_after})
    req_id
  end

  # Fires each pending resend at once instead of waiting it out, and returns the delay the
  # responder armed after each one. The message carries the delay it was armed with, rounded up
  # from the timer's remaining time.
  defp _fire_resends(pid, req_id, count) do
    %{responses: %{^req_id => {_response, first_ref}}} = :sys.get_state(pid)

    {_ref, armed_delays} =
      1..count
      |> Enum.reduce({first_ref, []}, fn _resend, {ref, armed_delays} ->
        delay = _armed_delay(ref)
        Process.cancel_timer(ref)
        send(pid, {:resend_response, req_id, delay})

        %{responses: %{^req_id => {_response, next_ref}}} = :sys.get_state(pid)
        {next_ref, [Process.read_timer(next_ref) | armed_delays]}
      end)

    Enum.reverse(armed_delays)
  end

  defp _armed_delay(ref) do
    remaining = Process.read_timer(ref)
    div(remaining + @resend_after - 1, @resend_after) * @resend_after
  end
end
