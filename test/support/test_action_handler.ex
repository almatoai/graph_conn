defmodule TestActionHandler do
  @moduledoc !"""
             Each execute function is executed in different task process.
             """

  use GraphConn.ActionApi.Handler
  alias GraphConn.ActionApi.Handler.Echo

  @impl GraphConn.ActionApi.Handler
  def execute(_req_id, "MakeDialyzerPass for `:ok` response", _),
    do: :ok

  def execute(_req_id, "ExecuteCommand", %{"other_handler" => "Echo"} = params),
    do: Echo.execute(params)

  def execute(_req_id, "ExecuteLocalCommand", %{"command" => "echo test"} = _params),
    do: {:ok, %{exec: "test\n"}}

  def execute(_req_id, "HTTP", params) do
    {:ok,
     %{
       "body" => params["body"],
       "code" => 201,
       "exec" =>
         "POST https://reqres.in/api/users?{\"version\":\"t1\"} {\"a\":1,\"b\":\"b\",\"c\":[{\"aa\":11,\"bb\":null}]}"
     }}
  end

  def execute(_req_id, "RunScript", %{"host" => "localhost"} = params) do
    {:ok, params}

    {:error, "the command does not point to an existing file"}
  end

  @impl GraphConn.ActionApi.Handler
  @spec default_execution_timeout(capability :: String.t()) :: non_neg_integer()
  def default_execution_timeout("ExecuteCommand"),
    do: 10_000

  @impl GraphConn.ActionApi.Handler
  @spec resend_response_timeout() :: non_neg_integer()
  def resend_response_timeout,
    do: 3_000
end
