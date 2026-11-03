defmodule GraphConn.ActionApi.InvokerLazyLogTest do
  @moduledoc """
  Whether the invoker builds a log message it is not going to log.
  """

  use ExUnit.Case, async: false

  alias GraphConn.Test.InspectProbe

  # The socket's own debug line inspects the whole request, so it is quieted to leave the
  # invoker's line as the only one that could inspect the params.
  setup do
    Logger.put_module_level(GraphConn.WsConnection, :warning)
    on_exit(fn -> Logger.delete_module_level([ActionInvoker, GraphConn.WsConnection]) end)
  end

  test "leaves an action's params uninspected while info logging is off" do
    Logger.put_module_level(ActionInvoker, :warning)
    params = %{"probe" => %InspectProbe{test_pid: self()}}

    assert {:error, _request_id, _reason} = _execute(params)
    refute_received :inspected
  end

  test "inspects an action's params when info logging is on" do
    Logger.put_module_level(ActionInvoker, :info)
    params = %{"probe" => %InspectProbe{test_pid: self()}}

    assert {:error, _request_id, _reason} = _execute(params)
    assert_received :inspected
  end

  # Unacked on purpose: only the log line before the send is under test.
  defp _execute(params) do
    request_id = UUID.uuid4()
    ActionInvoker.execute(request_id, "ah_id", "nack", params, ack_timeout: 1)
  end
end
