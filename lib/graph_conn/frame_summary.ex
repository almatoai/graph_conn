defmodule GraphConn.FrameSummary do
  @moduledoc "Names a frame in a log line by its type and id, never its payload, which can carry secrets."

  @doc """
  Returns `type=... id=...` for a frame map with atom or string keys, and no content at all for
  anything else.

      iex> GraphConn.FrameSummary.summarize(%{"type" => "submitAction", "id" => "r1", "parameters" => %{}})
      ~s(type="submitAction" id="r1")

      iex> GraphConn.FrameSummary.summarize(%{type: :ping})
      "type=:ping id=nil"

      iex> GraphConn.FrameSummary.summarize(nil)
      "not a map"
  """
  @spec summarize(frame :: term()) :: String.t()
  def summarize(%{} = frame) do
    type = _field(frame, :type)
    id = _field(frame, :id)
    "type=#{inspect(type)} id=#{inspect(id)}"
  end

  def summarize(_not_a_map),
    do: "not a map"

  defp _field(frame, key) do
    string_key = Atom.to_string(key)
    Map.get(frame, key) || Map.get(frame, string_key)
  end
end
