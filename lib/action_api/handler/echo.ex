defmodule GraphConn.ActionApi.Handler.Echo do
  @moduledoc """
  Trivial action handler used in tests. Echoes its params back, with optional
  `sleep`/`return_error`/`raise` hooks to exercise error and timing paths.
  """

  @doc """
  Echoes `params` back. Special keys: `"return_error"` returns `{:error, ...}`,
  `"sleep"` blocks for the given milliseconds before responding.
  """
  @spec execute(params :: map()) ::
          :ok
          | {:ok, any()}
          | {:error, {exit_code :: non_neg_integer(), response :: any()}}
          | {:error, any()}

  def execute(%{"return_error" => error}),
    do: {:error, error}

  def execute(%{"sleep" => sleep} = params) do
    Process.sleep(sleep)
    {:ok, params}
  end

  def execute(%{} = params),
    do: {:ok, params}
end
