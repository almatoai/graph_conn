defmodule GraphConn.ActionApi.InvokerTimeoutRefusalTest do
  @moduledoc """
  What the invoker logs when it refuses to send a request over its timeout.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias GraphConn.Mock

  test "the refusal names the request, the rejected value and that the caller gave it" do
    timeout = "soon-#{UUID.uuid4()}"
    params = %{"other_handler" => "Echo", "command" => "ls", "timeout" => timeout}
    execute = fn -> _execute("ExecuteCommand", params) end

    {result, log} = with_log(execute)

    assert {:error, req_id, {:not_sent, {:invalid_timeout, ^timeout}}} = result
    assert req_id == Logger.metadata()[:req_id]
    assert log =~ "timeout #{inspect(timeout)} from the caller is not"
  end

  test "the refusal says when the rejected value came from the capability defaults" do
    capability = "DefaultTimeout-#{UUID.uuid4()}"
    timeout = "soon-#{UUID.uuid4()}"
    capabilities = Jason.encode!(%{capability => %{"timeout" => timeout}})
    :ok = Mock.put_capabilities(capabilities)
    ActionInvoker.reconfigure()
    assert %{"timeout" => ^timeout} = ActionInvoker.capability_defaults(capability)
    execute = fn -> _execute(capability, %{"command" => "ls"}) end

    {result, log} = with_log(execute)

    assert {:error, req_id, {:not_sent, {:invalid_timeout, ^timeout}}} = result
    assert req_id == Logger.metadata()[:req_id]
    assert log =~ "timeout #{inspect(timeout)} from the capability defaults is not"
  end

  defp _execute(capability, params) do
    ticket_id = UUID.uuid4()
    ah_id = _ah_id()
    ActionInvoker.execute(ticket_id, ah_id, capability, params)
  end

  defp _ah_id do
    ActionInvoker.available_applicabilities()
    |> Map.keys()
    |> hd()
  end
end
