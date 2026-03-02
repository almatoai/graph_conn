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
