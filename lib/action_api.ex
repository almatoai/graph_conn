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
  """
  @type execution_error() ::
          :not_found
          | {:ack_timeout, timeout :: pos_integer()}
          | {:exec_timeout, timeout :: pos_integer()}
          | {:action_api_returned_timeout, last_status :: String.t()}
          | {:handler_returned_timeout, timeout :: pos_integer()}
          | {:nack, error :: term()}
end
