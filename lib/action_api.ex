defmodule GraphConn.ActionApi do
  @moduledoc """
  Shared types for the ActionAPI (invoker + handler).

  The actual functions are defined in `GraphConn.ActionApi.Invoker` and
  `GraphConn.ActionApi.Handler`; this module just collects the error/result
  types they both reference.
  """

  @typedoc """
  Execution error explanation:

  - `not_found` - Requested action_handler_id and capability_name is
    not found as valid combination for this client.
  - `{:ack_timeout, timeout}` - Graph didn't receive message in specified `timeout`.
  - `{:exec_timeout, timeout}` - Graph didn't respond in specified `timeout`.
  - `{:action_api_returned_timeout, last_status}` - ActionAPI returned timeout message on last call with `last_status` request was in.
  - `{:handler_returned_timeout, timeout}` - Handler returned timeout message (execution on AH side didn't finish in `timeout` ms)
  - `{:rate_limited, retry_after_ms}` - Request was never sent, because the Graph answered a `429`.
    Only a rate limit produces this. `retry_after_ms` is how long to wait before retrying, in
    milliseconds, and is `0` once the window has already passed. A duration rather than a
    timestamp, so it stays meaningful when the error is passed on to another node.
  - `{:not_sent, reason}` - Request was never sent, because the connection could not be
    established. Distinct from `{:rate_limited, _}`, which is the only one worth waiting on, and
    from `{:nack, _}`, which means the Graph received the request and rejected it.

    The recognised reasons are `{:upgrade_refused, status}`, `:not_connected`,
    `:ws_connection_down`, `:not_started` and `{:unknown_api, apis}`. **The set is not closed**:
    a transport failure passes through as whatever it was -- `:recv_timeout`, `:gun_down`, a gun
    error term. Match the recognised ones if you act on them, and LOG anything else rather than
    matching it, or a new transport failure becomes a crash in your caller.
  """
  @type execution_error() ::
          :not_found
          | {:ack_timeout, timeout :: pos_integer()}
          | {:exec_timeout, timeout :: pos_integer()}
          | {:action_api_returned_timeout, last_status :: String.t()}
          | {:handler_returned_timeout, timeout :: pos_integer()}
          | {:nack, error :: term()}
          | {:rate_limited, retry_after_ms :: non_neg_integer()}
          | {:not_sent, reason :: term()}
end
