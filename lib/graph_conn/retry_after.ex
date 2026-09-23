defmodule GraphConn.RetryAfter do
  @moduledoc """
  Reads an HTTP `retry-after` response header and converts it to milliseconds.

  HTTP only, by design: the WS path advertises its wait in milliseconds inside a JSON frame,
  and one parser over two units invites an off-by-1000.
  """

  require Logger

  # A day is longer than any window a rate limiter enforces, and far inside what
  # `Process.send_after/3` accepts -- an unclamped bignum raises there, inside the caller.
  @max_wait_in_ms 86_400_000

  @doc """
  Returns the wait advertised in a `retry-after` header, in milliseconds, capped at a day.

  Only delay-seconds is read. RFC 9110 also permits an HTTP-date, which is deliberately not
  parsed: no producer sends one, and a date comes back `:error`, which callers already read as
  "no wait advertised" and answer with their own backoff curve — so supporting it would behave
  no differently. A missing, malformed or non-positive value is `:error` for the same reason: a
  wait of no time at all is not representable.
  """
  @spec parse(headers :: [{name :: String.t(), value :: String.t()}]) ::
          {:ok, wait_in_ms :: pos_integer()} | :error
  def parse(headers) do
    headers
    |> _find_header()
    |> case do
      nil -> :error
      value -> _parse_value(value)
    end
  end

  @doc """
  Normalizes a 429's headers into the internal rate-limited error.

  A wait of `0` means the response advertised none, or advertised one this client cannot use;
  callers read either as "back off on your own curve". The two are logged apart, because an
  operator chasing a misbehaving rate limiter needs to know which it was. Shared by the REST and
  WebSocket-upgrade paths so the two cannot drift.
  """
  @spec rate_limited(headers :: [{name :: String.t(), value :: String.t()}]) ::
          {:error, {:rate_limited, wait_in_ms :: non_neg_integer()}}
  def rate_limited(headers) do
    headers
    |> parse()
    |> case do
      {:ok, advertised_ms} ->
        Logger.warning("[GraphConn.RetryAfter] 429 received, advertised wait #{advertised_ms}ms")

        {:error, {:rate_limited, advertised_ms}}

      :error ->
        _no_usable_wait(headers)
    end
  end

  defp _no_usable_wait(headers) do
    headers
    |> _find_header()
    |> case do
      nil ->
        Logger.warning("[GraphConn.RetryAfter] 429 received with no retry-after header")

      value ->
        Logger.warning(
          "[GraphConn.RetryAfter] 429 received with an unusable retry-after #{inspect(value)}"
        )
    end

    {:error, {:rate_limited, 0}}
  end

  defp _find_header(headers) do
    headers
    |> Enum.find(fn {name, _value} -> String.downcase(name) == "retry-after" end)
    |> case do
      {_name, value} -> value
      nil -> nil
    end
  end

  defp _parse_value(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {seconds, ""} -> _bounded_wait(seconds * 1_000)
      _not_delay_seconds -> :error
    end
  end

  # Logs the advertised magnitude rather than the clamped one: a raw value in the billions is
  # the only signal that a producer started sending a timestamp instead of delay-seconds.
  defp _bounded_wait(wait_in_ms) when wait_in_ms > @max_wait_in_ms do
    Logger.warning(
      "retry-after advertised #{wait_in_ms}ms, past the #{@max_wait_in_ms}ms this client will " <>
        "wait; a value this large means the header is no longer delay-seconds."
    )

    {:ok, @max_wait_in_ms}
  end

  defp _bounded_wait(wait_in_ms) when wait_in_ms > 0,
    do: {:ok, wait_in_ms}

  defp _bounded_wait(_elapsed_or_zero),
    do: :error
end
