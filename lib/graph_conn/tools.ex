defmodule GraphConn.Tools do
  @moduledoc false

  # Set of tool functions for internal library use.

  @doc """
  Converts value to integer if it is binary or returns it as-is
  """
  @spec to_integer(value :: String.t() | integer()) :: integer()
  def to_integer(value) when is_binary(value), do: String.to_integer(value)
  def to_integer(value) when is_integer(value), do: value
end
