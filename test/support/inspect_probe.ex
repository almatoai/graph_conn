defmodule GraphConn.Test.InspectProbe do
  @moduledoc "A value that sends `:inspected` to `test_pid` every time it is inspected."

  @derive {Jason.Encoder, only: []}
  defstruct [:test_pid]

  defimpl Inspect do
    @spec inspect(probe :: GraphConn.Test.InspectProbe.t(), opts :: Inspect.Opts.t()) ::
            String.t()
    def inspect(%{test_pid: test_pid}, _opts) do
      send(test_pid, :inspected)
      "#InspectProbe<>"
    end
  end

  @type t :: %__MODULE__{test_pid: pid() | nil}
end
