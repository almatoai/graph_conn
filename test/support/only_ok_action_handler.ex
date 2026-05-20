defmodule OnlyOkActionHandler do
  @moduledoc !"""
             Regression fixture for the Elixir 1.18 type-narrowing warning
             on `GraphConn.ActionApi.Handler`'s `_execute_action/3` dispatch.

             All `execute/3` clauses return `{:ok, _}` only. If the macro
             ever reverts to a local `execute/3` call, the set-theoretic
             type checker narrows the inferred return type and the
             library's `{:error, _}` branch is flagged unreachable under
             `mix compile --warnings-as-errors --force`.
             """

  use GraphConn.ActionApi.Handler

  @impl GraphConn.ActionApi.Handler
  def execute(_req_id, "Echo", %{"msg" => msg}),
    do: {:ok, %{"echo" => msg}}

  def execute(_req_id, "Noop", _params),
    do: {:ok, %{}}
end
