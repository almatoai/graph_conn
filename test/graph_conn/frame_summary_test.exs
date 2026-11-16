defmodule GraphConn.FrameSummaryTest do
  use ExUnit.Case, async: true

  alias GraphConn.FrameSummary

  doctest FrameSummary

  describe "summarize/1" do
    test "leaves everything but type and id out" do
      frame = %{"type" => "token", "id" => "r1", "_TOKEN" => "s3cret"}

      refute FrameSummary.summarize(frame) =~ "s3cret"
    end
  end
end
