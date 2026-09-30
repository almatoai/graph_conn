defmodule GraphConn.ActionApi.ResultFrame do
  @moduledoc "Keeps an action result frame within the server's frame limit."

  alias GraphConn.Request
  require Logger

  @too_big_status 59

  @doc """
  Returns `request`, with its result swapped for an `action_status` #{@too_big_status} error when
  the encoded frame exceeds `max_frame_bytes`. Frames other than `sendActionResult` pass through
  untouched.
  """
  @spec fit(request :: Request.t(), max_frame_bytes :: pos_integer()) :: Request.t()
  def fit(%Request{body: %{type: "sendActionResult"} = body} = request, max_frame_bytes) do
    frame_bytes =
      body
      |> Jason.encode!()
      |> byte_size()

    _fit(request, frame_bytes, max_frame_bytes)
  end

  def fit(%Request{} = request, _max_frame_bytes),
    do: request

  defp _fit(request, frame_bytes, max_frame_bytes) when frame_bytes <= max_frame_bytes,
    do: request

  defp _fit(%Request{body: body} = request, frame_bytes, max_frame_bytes) do
    message = "Response was too big (#{_mb(frame_bytes)} MB, limit #{_mb(max_frame_bytes)} MB)"
    Logger.warning("[ActionHandler] #{message}, sending an error instead", req_id: body.id)
    error = %{req_id: body.id, action_status: @too_big_status, action_error: message}
    result = Jason.encode!(%{error: error})

    %Request{request | body: %{body | result: result}}
  end

  defp _mb(bytes) do
    bytes
    |> Kernel./(1_000_000)
    |> :erlang.float_to_binary(decimals: 2)
  end
end
