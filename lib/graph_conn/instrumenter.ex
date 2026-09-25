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
  Returns the time elapsed since `mono_start` as both measurements a timed event carries.

  `:duration` is milliseconds, the unit consumers have always read. `:duration_native` is the same
  interval unconverted, matching `:telemetry.span/3`, for a consumer that needs resolution finer
  than a millisecond -- a local call such as a WebSocket send usually takes less than one.

  Both come from a single reading, so they cannot disagree.
  """
  @spec durations(mono_start :: integer()) :: %{duration: integer(), duration_native: integer()}
  def durations(mono_start) do
    elapsed = System.monotonic_time() - mono_start

    %{
      duration: System.convert_time_unit(elapsed, :native, :millisecond),
      duration_native: elapsed
    }
  end

  @doc """
  Returns elapsed time in milliseconds since `mono_start` (a monotonic-time reading).
  """
  @spec duration(mono_start :: integer()) :: integer()
  def duration(mono_start) do
    mono_start
    |> durations()
    |> Map.fetch!(:duration)
  end
end
