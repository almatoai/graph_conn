defmodule GraphConn.ActionApi.InvokerLazyLogTest do
  @moduledoc """
  Whether any log line inspects an action's params.
  """

  use ExUnit.Case, async: false

  alias GraphConn.Test.InspectProbe

  @debug_modules [ActionInvoker, GraphConn.WsConnection, GraphConn.WS]

  setup do
    Logger.put_module_level(@debug_modules, :debug)
    on_exit(fn -> Logger.delete_module_level(@debug_modules) end)
  end

  test "leaves an action's params uninspected even at debug" do
    params = %{"probe" => %InspectProbe{test_pid: self()}}

    assert {:error, _request_id, _reason} = _execute(params)
    refute_received :inspected
  end

  # Unacked on purpose: only the log lines around the send are under test.
  defp _execute(params) do
    request_id = UUID.uuid4()
    ActionInvoker.execute(request_id, "ah_id", "nack", params, ack_timeout: 1)
  end
end
