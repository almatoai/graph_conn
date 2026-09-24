defmodule GraphConn.RetryAfterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias GraphConn.RetryAfter

  describe "parse/1" do
    test "converts delay-seconds to milliseconds, read as a delta not an absolute time" do
      # Read as an epoch timestamp, "2" would be two seconds after 1970 and come back :error.
      # The wire format is a delta, and this pins that reading rather than leaving it implicit
      # in the arithmetic.
      assert {:ok, 2_000} == RetryAfter.parse([{"retry-after", "2"}])
    end

    test "finds the header whatever its casing" do
      assert {:ok, 3_000} == RetryAfter.parse([{"Retry-After", "3"}])
    end

    test "ignores the headers around it" do
      headers = [{"content-type", "application/json"}, {"retry-after", "5"}]

      assert {:ok, 5_000} == RetryAfter.parse(headers)
    end

    test "tolerates surrounding whitespace" do
      assert {:ok, 7_000} == RetryAfter.parse([{"retry-after", " 7 "}])
    end

    test "does not parse a date, so an HTTP-date degrades to the plain curve" do
      # RFC 9110 permits an HTTP-date and no producer sends one. `:error` is already how a
      # caller reads "nothing was advertised", so declining to parse it costs nothing.
      assert :error == RetryAfter.parse([{"retry-after", "Sun, 06 Nov 2094 08:49:37 GMT"}])
    end

    test "refuses a zero wait rather than reporting a wait of no time at all" do
      assert :error == RetryAfter.parse([{"retry-after", "0"}])
    end

    test "refuses a negative wait" do
      assert :error == RetryAfter.parse([{"retry-after", "-5"}])
    end

    test "refuses a value that is neither seconds nor a date" do
      assert :error == RetryAfter.parse([{"retry-after", "soon"}])
    end

    test "refuses seconds with trailing junk" do
      assert :error == RetryAfter.parse([{"retry-after", "2s"}])
    end

    test "clamps a wait no rate limiter could legitimately advertise" do
      {result, _log} =
        with_log(fn -> RetryAfter.parse([{"retry-after", "99999999999999999999"}]) end)

      assert {:ok, 86_400_000} == result
    end

    test "logs the advertised magnitude, not the clamped one, when it clamps" do
      {result, log} = with_log(fn -> RetryAfter.parse([{"retry-after", "1789012560"}]) end)

      assert {:ok, 86_400_000} == result

      # The raw magnitude is the whole point: 86400000ms reads as someone configuring a silly
      # wait, whereas 1789012560000ms reads unmistakably as a unix timestamp in a header that
      # is supposed to carry delay-seconds. It is the only signal of that format change.
      assert log =~ "1789012560000ms"
    end

    test "returns a wait Process.send_after/3 will accept" do
      {result, _log} =
        with_log(fn -> RetryAfter.parse([{"retry-after", "99999999999999999999"}]) end)

      assert {:ok, wait_in_ms} = result

      # Unclamped this raises ArgumentError inside ConnectionManager, which is the crash class
      # this whole change exists to remove.
      ref = Process.send_after(self(), :never, wait_in_ms)
      assert is_integer(Process.cancel_timer(ref))
    end

    test "reports no wait when the header is absent" do
      assert :error == RetryAfter.parse([{"content-type", "application/json"}])
    end

    test "reports no wait when there are no headers at all" do
      assert :error == RetryAfter.parse([])
    end
  end

  describe "from_ms/1" do
    test "takes a wait a WebSocket frame already expressed in milliseconds" do
      assert 1_986 == RetryAfter.from_ms(1_986)
    end

    test "takes a wait written with a decimal point, which JSON decodes as a float" do
      assert 1_986 == RetryAfter.from_ms(1_986.0)
    end

    test "reads anything that is not a wait as none advertised" do
      for not_a_wait <- [nil, "1986", -1, 0, 0.5, :infinity, %{}] do
        assert 0 == RetryAfter.from_ms(not_a_wait)
      end
    end

    test "caps a wait no gateway could legitimately advertise, so a caller can arm a timer on it" do
      assert 86_400_000 == RetryAfter.from_ms(999_999_999_999)
    end
  end

  describe "rate_limited/1" do
    test "normalizes a 429's headers into the internal error" do
      {result, _log} = with_log(fn -> RetryAfter.rate_limited([{"retry-after", "2"}]) end)

      assert {:error, {:rate_limited, 2_000}} == result
    end

    test "reports a zero wait when the 429 advertised none" do
      # Zero is how the REST and upgrade paths both say "denied, but pick your own delay".
      {result, _log} = with_log(fn -> RetryAfter.rate_limited([]) end)

      assert {:error, {:rate_limited, 0}} == result
    end

    test "says a 429 was received, so a denial is visible without the caller logging it" do
      {_result, log} = with_log(fn -> RetryAfter.rate_limited([{"retry-after", "2"}]) end)

      assert log =~ "429 received"
      assert log =~ "2000ms"
    end

    test "says the header was missing rather than reporting a wait of zero" do
      {_result, log} = with_log(fn -> RetryAfter.rate_limited([]) end)

      assert log =~ "no retry-after header"
      refute log =~ "advertised wait"
    end

    test "quotes a retry-after it cannot use, so it reads apart from an absent one" do
      {_result, log} = with_log(fn -> RetryAfter.rate_limited([{"retry-after", "later"}]) end)

      assert log =~ "unusable"
      assert log =~ "later"
      refute log =~ "no retry-after header"
    end

    test "names itself, so the line is attributable without the caller's prefix" do
      {_result, log} = with_log(fn -> RetryAfter.rate_limited([]) end)

      assert log =~ "[GraphConn.RetryAfter]"
    end
  end
end
