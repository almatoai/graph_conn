# 1.10.0

First release that supports running behind a rate-limiting WebSocket gateway.

## Enhancement

- Retries on authentication, API-version discovery and WebSocket upgrade wait for the
  `retry-after` seconds a 429 advertises, on a capped and jittered curve. Tunable via
  `:retry_initial_ms` (1_000), `:retry_max_ms` (10_000), `:retry_jitter_ms` (1_000) and
  `:retry_floor_max_ms` (300_000, the sanity ceiling on an advertised wait).
- A refused WebSocket upgrade no longer restarts the client's supervision subtree.
- `GraphConn.Mock.put_token_lifetime/2` sets the lifetime the mock server issues for a given token,
  so a suite can exercise a short-lived or already-expired one. Scoped to a single token, since
  several clients share the mock; unset, every token lives ten minutes as before.
- `GraphConn.ActionApi.Invoker.State` no longer carries `ws_status`. It was written once and never
  read, and every WebSocket status change after the first was logged as unhandled.
- `status/1` takes a timeout. The manager answering it shares a mailbox with token refreshes, so
  it can be busy for as long as one takes; without this the wait was fixed at five seconds and
  overrunning it exited the calling process.
- The access token is now refreshed before it expires rather than at the instant it does, so a
  connection opened near expiry no longer carries a dead token. Tunable via
  `:token_refresh_ratio` (0.95 of the token's lifetime), with a floor of three times
  `:retry_max_ms` so a short-lived token keeps a margin wide enough to outlast a run of denials.

## Fix

- An in-band rate-limit denial on the action-ws socket is answered to the caller that sent the
  request, as `{:error, request_id, {:rate_limited, retry_after_ms}}`, instead of timing out and
  resending into the same limiter. A denial carrying no request id belongs to no caller and is
  logged rather than answered. An advertised wait that is not a positive integer reads as `0`,
  "back off on your own curve", and one past a day is capped.
- An `events-ws` status change other than `:ready` no longer raises in a consumer's
  `on_status_change/3`. The callback had no catch-all, so every drop, refusal or reopen was a
  `FunctionClauseError` inside `ConnectionManager` and took the client's subtree down with it.
- A WebSocket connection the Graph closes with `1008` is no longer reopened on the backoff curve.
  Reconnecting with a token the Graph just refused can only be refused again; the close reaches
  `on_status_change/3` as `{:disconnected, {:rejected_by_server, message}}`, and the connection is
  reopened once a new token arrives.
- A token refresh the Graph rejects now answers the caller with `{:error, :wrong_credentials}`
  instead of crashing the connection manager and, under `:one_for_all`, the client with it.
- Retrying a `401` no longer exits the caller when authentication runs longer than five seconds.
  The wait now follows the configured `:auth` timeout it is waiting on.
- A token whose `expires-at` has already passed no longer takes the client down. It is kept and the
  client stays `:ready` — the clock may be ours, not the Graph's — and the refresh is scheduled on
  the retry curve with a warning naming the likely cause, rather than immediately.

## Change

- A request that cannot go out because the Graph answered a `429` now comes back as an error
  rather than blocking or raising: `GraphConn.execute/3` against a WebSocket API returns
  `{:error, {:rate_limited, retry_after_ms}}`, and an action invoker's `execute/5` returns
  `{:error, request_id, {:rate_limited, retry_after_ms}}`, which is added to
  `ActionApi.execution_error()`. `retry_after_ms` is how long to wait, `0` once the window has
  passed. Only a `429` reports as rate limited; an action invoker reports any other unsendable
  request as `{:error, request_id, {:not_sent, reason}}`, also added to
  `ActionApi.execution_error()`.
- BREAKING: a request against a WebSocket API whose connection is down now returns
  `{:error, :ws_connection_down}` rather than blocking until the connection came back and then
  succeeding. A reopen already on the clock is waited out first, so an ordinary drop does not fail
  the requests made during it; the caller blocks for at most `:retry_max_ms + :startup_wait_ms`,
  10.5s on the defaults, which is what a consumer's own request timeout has to accommodate.
- Depends on the published `gun ~> 2.1` instead of a fork of it. Connecting to the Graph through a
  client's HTTP proxy is unchanged.
- A WebSocket connection that drops is now reopened on the backoff curve rather than immediately,
  so the first reconnect after a drop waits between one and two times `:retry_initial_ms` instead
  of no time at all. A request made during that window waits the reopen out and is resent once the
  connection is back.

# 1.9.13

## Fix

- `execute/3` no longer blocks forever when no connection is running for the client. The wait for
  the table and the API versions themselves is now capped at `:startup_wait_ms` (`config
  :graph_conn, startup_wait_ms: ms`, 500 by default, `0` to fail immediately) after which the call
  returns `{:error, :not_started}`.

# 1.9.12

## Enhancement

- Add configurable `conn_max_idle_time` Finch pool option. Set
  `config :graph_conn, conn_max_idle_time: ms` to proactively drop idle
  HTTP connections before the upstream gateway closes them. Defaults to
  `nil` (Finch default: `:infinity`, preserving existing behaviour).

# 1.9.11

## Update

- Use elixir 1.20.0 and otp 29.0.1 and fix new warnings

## Enhancement

- Make sure bless fails if coveralls fails.

# 1.9.10

## Enhancement

- Catch all `%{reason: reason}` error responses during authentication, not only from `Finch`

# 1.9.9

## Change

- `config/dev.exs` now reads `ActionInvoker.url` and `ActionHandler.url`
  from `INVOKER_URL` and `HANDLER_URL` env vars with the prior literals
  as defaults.
- `mix bless` now runs `credo --strict`, `sobelow --exit low`, and
  `deps.audit` (matches sibling Elixir apps). `.credo.exs` adds two
  project-specific custom checks under `test/support/credo_checks/`:
  `PrivateFunctionUnderscore` (defp `_name` rule) and `NoPipeInsideCall`.

## Enhancement

- Prevent warnings in compile time if ActionHandler doesn't return `{:error, error}` from `execute/3` callback
- Add `@moduledoc` to public lib modules; add `@spec` on previously
  unannotated public functions to enable `credo --strict`.

# 1.9.8

## Bug fix

- Request now internally normalizes header names to avoid erroneous addition of 'Authorization'
  header if one is already present, albeit with different casing.
- For requests with expired provided authorization header (on-behalf auth), no token refresh is
  attempted to prevent an infinite loop.

# 1.9.7

## Change

- Remove audit and sobelow checks from `mix bless` task

# 1.9.6

## Enhancement

- Add `auto_connect` option in graph_conn that accepts `true`, `false` or `:just_versions`
- Add `events-ws` handler

# 1.9.5

## Enhancement

- Remove response size check. It will be done in client.

# 1.9.4

## Enhancement

- When there are multiple tasks waiting for the same response, respond only to the latest one

# 1.9.3

## Update

- Use elixir 1.18.1 and otp 27.2
- Update all deps to their latest versions

# 1.9.2

## Bug fix

- Requires otp >= 25
- use correctly custom CA if one is set

- BREAKING: if http request (not https) is used to connect to graph or mock,
  following is mandatory, otherwise finch will crash:

  ```elixir
  config :graph_conn, insecure: true
  ```

# 1.9.1

## Enhancements

- Allow `config :graph_conn, ca_cert: "/absolute/path/to/my_cert.crt"` to be set

# 1.9.0

## Enhancements

- BREAKING: Invoker returns req_id in error messages

## Bugfix

- Use patched gun

# 1.8.1

## Enhancements

- Bump gun to ~> 2.1.0

# 1.8.0

## Enhancements

- Invoker doesn't send request again on nack
- More descriptive handling of dropped ws connections
- Make `cachex` optional (only needed by action_handler)
- Explicit support of new action-api features:
  - Log "hello" message when ws connection is successfully established
  - Invoker sends "last call" instead of immediate timeout (maybe cached response is waiting but wasn't delivered)
  - More descriptive timeout messages (with last success status in action api)
- CI tests for elixir >= 1.15

# 1.7.2

## Enhancements

- Wait with rejecting unknown api if no apis are registered yet

# 1.7.1

## Maintenance

- remove `murmur` and clean unused dependencies

# 1.7.0

## Enhancements

- make ws ping interval configurable

## Breaking change:

- `GraphConn.ActionApi.Handler`'s `execute/2` changed to `execute/3`, adding `req_id` as first argument

# 1.6.1

## Enhancements

- reduce ping/pong interval and make it configurable

# 1.5.5

## 1. Bug fix

- Fix connection to graph via proxy

# 1.5.4

## 1. Bug fix

- Fix crashing logging when proxy is used

# 1.5.3

## 1. Enhancements

- Invoker will wait timeout + 1sec so handler have time to return timeout message.
- Allow connection to graph via proxy

# 1.5.2

## 1. Enhancements

- Allow `config :graph_conn, insecure: true` to force insecure SSL connections

# 1.5.1

## 1. Bug fix

- Fix ssl options for ws connection

# 1.5.0

## 1. Enhancements

- Use `finch` lib for REST requests instead of `machine_gun`.

# 1.4.1

## 1. Enhancements

- Update all deps and fix dialyzer errors

# 1.4.0

## 1. Bug fix

- Action executions are not performed inside Cachex process

# 1.3.2

## 1. Bug fix

- Processes will now unregister themself after execution

# 1.3.1

## 1. Enhancements

- Update dependencies for later erlang compatibility

# 1.3.0

## 1. Enhancements

- Replace con_cache with cachex.

# 1.2.0

## 1. Bug fix

- Make request_id for action api deterministic.

# 1.1.5

## 1. Enhancements

- Process ws response and prepare request out of Connection process.

# 1.1.4

## 1. Bug fixes

- Fix problem with RequestRegistry when ack/nack is received for already processed request.

# 1.1.3

## 1. Enhancements

- Send WS and REST related telemetry events

# 1.1.2

## 1. Bug fix

- Action Handler will pass on inspected error if error not json encodable

# 1.1.1

## 1. Bug fix

- Action Invoker ignores received response if it can't find request_id in registry 5 times with a second wait time

# 1.1.0

## 1. Enhancements

- Default (local) request registry can be changed with clients (distributed) version

# 1.0.4

## 1. Enhancements

- Generate smaller request ids by using murmur hash

# 1.0.3

## 1. Enhancements

- Improve logging for Action API

## 2. Bug fix

- Fix stopping ws connection on missing pongs.

# 1.0.2

## 1. Enhancements

- Default authentication to 60sec
- Allow `timeout` in graph_con config for default execution timeout (defaults to 5 sec).
- Allow `timeout` in graph_coni[:auth] config for default authentication timeout (defaults to 60 sec).

# 1.0.1

## 1. Enhancements

- Stop GraphConn process if authentication returns 401
- Exponentially increase delay between two unsuccessful authentications
- Require cowlib ~> 2.9.1

# 1.0.0

## 1. Enhancements

- Handle GOAWAY message sent by server.
