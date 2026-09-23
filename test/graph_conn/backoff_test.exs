defmodule GraphConn.BackoffTest do
  use ExUnit.Case, async: true

  alias GraphConn.Backoff

  describe "next/2" do
    test "doubles the current delay" do
      assert 2_000 == Backoff.next(1_000, 10_000)
    end

    test "clamps the doubling at the cap" do
      assert 10_000 == Backoff.next(8_000, 10_000)
      assert 10_000 == Backoff.next(10_000, 10_000)
    end
  end

  describe "jitter/1" do
    test "spreads within the delay without ever exceeding it" do
      for _attempt <- 1..500 do
        jittered = Backoff.jitter(1_000)

        assert jittered > 500
        assert jittered <= 1_000
      end
    end

    test "leaves the smallest possible delay alone" do
      assert 1 == Backoff.jitter(1)
    end
  end

  describe "next_delay/4" do
    test "sleeps on the jittered curve when nothing was advertised" do
      for _attempt <- 1..200 do
        assert {delay, 2_000} = Backoff.next_delay(1_000, 0, 10_000, 1_000)

        assert delay > 1_000
        assert delay <= 2_000
      end
    end

    test "advances the curve to the cap and no further" do
      assert {_delay, 10_000} = Backoff.next_delay(8_000, 0, 10_000, 1_000)
      assert {_delay, 10_000} = Backoff.next_delay(10_000, 0, 10_000, 1_000)
    end

    test "an advertised wait longer than the cap wins over the cap" do
      for _attempt <- 1..200 do
        assert {delay, _next_current} = Backoff.next_delay(1_000, 90_000, 10_000, 1_000)

        assert delay > 90_000
        assert delay <= 91_000
      end
    end

    test "spread above an advertised wait is additive, never a reduction" do
      for _attempt <- 1..200 do
        assert {delay, _next_current} = Backoff.next_delay(1_000, 2_000, 10_000, 1_000)

        assert delay > 2_000
      end
    end

    test "an advertised wait never contaminates the curve" do
      assert {_delay, 2_000} = Backoff.next_delay(1_000, 90_000, 10_000, 1_000)
    end

    test "an advertised wait shorter than the curve leaves the curve in charge" do
      for _attempt <- 1..200 do
        assert {delay, 2_000} = Backoff.next_delay(1_000, 1, 10_000, 1)

        assert delay > 1_000
        assert delay <= 2_000
      end
    end
  end

  describe "next_delay/4 under misconfiguration" do
    test "a negative cap yields neither a negative delay nor a stalled curve" do
      for _attempt <- 1..200 do
        assert {delay, next_current} = Backoff.next_delay(1_000, 0, -5, 1_000)

        assert delay > 0
        assert next_current >= 1
      end
    end

    test "a zero cap cannot strand the curve at zero" do
      assert {delay, next_current} = Backoff.next_delay(1_000, 0, 0, 1_000)

      assert delay > 0
      assert next_current >= 1
    end

    test "a zero seed still advances the curve" do
      assert {delay, next_current} = Backoff.next_delay(0, 0, 10_000, 1_000)

      assert delay > 0
      assert next_current >= 1
    end

    test "a negative seed still advances the curve" do
      assert {delay, next_current} = Backoff.next_delay(-5, 0, 10_000, 1_000)

      assert delay > 0
      assert next_current >= 1
    end

    test "a zero spread above an advertised wait does not raise" do
      assert {delay, _next_current} = Backoff.next_delay(1_000, 2_000, 10_000, 0)

      assert delay > 2_000
    end

    test "a negative spread above an advertised wait does not raise" do
      assert {delay, _next_current} = Backoff.next_delay(1_000, 2_000, 10_000, -5)

      assert delay > 2_000
    end
  end
end
