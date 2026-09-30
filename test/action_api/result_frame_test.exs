defmodule GraphConn.ActionApi.ResultFrameTest do
  use ExUnit.Case, async: true

  alias GraphConn.ActionApi.ResultFrame
  alias GraphConn.Request

  defp _result_request(req_id, result_bytes) do
    result = Jason.encode!(%{data: String.duplicate("a", result_bytes)})
    %Request{body: %{id: req_id, type: "sendActionResult", result: result}}
  end

  defp _frame_bytes(%Request{body: body}) do
    body
    |> Jason.encode!()
    |> byte_size()
  end

  describe "fit/2" do
    test "leaves a result that fits the frame limit untouched" do
      request = _result_request("req-small", 100)

      assert request == ResultFrame.fit(request, 1_000_000)
    end

    test "leaves a result exactly at the frame limit untouched" do
      request = _result_request("req-exact", 1_000)
      limit = _frame_bytes(request)

      assert request == ResultFrame.fit(request, limit)
    end

    test "replaces a result over the frame limit with an action_status 59 error" do
      request = _result_request("req-big", 1_500_000)

      assert %Request{body: %{id: "req-big", type: "sendActionResult", result: result}} =
               ResultFrame.fit(request, 1_000_000)

      assert %{
               "error" => %{
                 "req_id" => "req-big",
                 "action_status" => 59,
                 "action_error" => "Response was too big (1.50 MB, limit 1.00 MB)"
               }
             } == Jason.decode!(result)
    end

    test "the replacement fits the frame limit" do
      request = _result_request("req-big", 5_000)

      fitted_bytes =
        request
        |> ResultFrame.fit(1_000)
        |> _frame_bytes()

      assert fitted_bytes <= 1_000
    end

    test "leaves a frame that is not a result untouched, whatever its size" do
      request = %Request{body: %{id: "req-ack", type: "acknowledged", code: 200, message: ""}}

      assert request == ResultFrame.fit(request, 1)
    end
  end
end
