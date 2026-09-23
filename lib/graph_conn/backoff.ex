defmodule GraphConn.Backoff do
  @moduledoc """
  Pure retry-delay arithmetic: a capped doubling curve, jittered, with an optional floor.

  `next/2` and `jitter/1` define the curve the same way `ws-proxy` does, so the two repos
  back off identically. Config resolution and logging belong to the caller — nothing here
  reads application env.
  """

  @doc "Doubles `current`, never going past `cap`."
  @spec next(current :: pos_integer(), cap :: pos_integer()) :: pos_integer()
  def next(current, cap),
    do: min(current * 2, cap)

  @doc "Spreads `delay` over `(delay / 2, delay]`, so jitter can only shorten a wait."
  @spec jitter(delay :: pos_integer()) :: pos_integer()
  def jitter(delay) do
    half = div(delay, 2)
    bound = max(half, 1)
    half + :rand.uniform(bound)
  end

  @doc """
  Returns the delay to wait and the curve value to carry into the next attempt.

  `floor_ms` is a wait the server advertised; `0` means it advertised none. A floor wins over
  `cap`, because waiting less than the server asked for is a certain second denial, and `spread`
  is added above it rather than jittered into it, so handlers sharing one window boundary scatter
  without any of them retrying early. The returned curve value ignores `floor_ms` entirely, so a
  single long advertised wait cannot poison every later retry.

  Every domain clamp lives here: a non-positive `cap`, `spread` or `current` is absorbed rather
  than turned into a negative delay, which `Process.send_after/3` would raise on.
  """
  @spec next_delay(
          current :: non_neg_integer(),
          floor_ms :: non_neg_integer(),
          cap :: integer(),
          spread :: integer()
        ) :: {delay :: pos_integer(), next_current :: pos_integer()}
  def next_delay(current, floor_ms, cap, spread) do
    sane_cap = max(cap, 1)

    next_current =
      current
      |> max(1)
      |> next(sane_cap)

    curve = jitter(next_current)

    delay =
      floor_ms
      |> case do
        0 ->
          curve

        floor ->
          bound = max(spread, 1)
          scattered = floor + :rand.uniform(bound)
          max(curve, scattered)
      end

    {delay, next_current}
  end
end
