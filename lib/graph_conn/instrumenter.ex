defmodule GraphConn.Instrumenter do
  @moduledoc """
  Thin `:telemetry` wrapper. All events are emitted under the `[:graph_conn, …]`
  prefix so consumers can attach handlers without depending on internal names.
  """

  @doc """
  Emits telemetry event `[:graph_conn, name]` with `measurements` and `data`.
  """
  @spec execute(name :: atom(), measurements :: map(), data :: map()) :: :ok
  def execute(name, measurements \\ %{}, data \\ %{}),
    do: :telemetry.execute([:graph_conn, name], measurements, data)

  @doc """
  Returns elapsed time in milliseconds since `mono_start` (a monotonic-time reading).
  """
  @spec duration(mono_start :: integer()) :: integer()
  def duration(mono_start) do
    (System.monotonic_time() - mono_start)
    |> System.convert_time_unit(:native, :millisecond)
  end
end
