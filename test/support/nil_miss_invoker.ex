defmodule GraphConn.Test.NilMissRegistry do
  @moduledoc """
  A request registry that knows no request and answers a lookup miss with `nil`, as a distributed
  registry still waiting for the caller's registration to arrive does.
  """

  @behaviour GraphConn.ActionApi.Invoker.RequestRegistry

  @impl true
  @spec register_self(registry :: atom(), request_id :: term()) :: :ok
  def register_self(_registry, _request_id),
    do: :ok

  @impl true
  @spec lookup(registry :: atom(), request_id :: term()) :: nil
  def lookup(_registry, _request_id),
    do: nil

  @impl true
  @spec unregister(registry :: atom(), request_id :: term()) :: :ok
  def unregister(_registry, _request_id),
    do: :ok
end

defmodule GraphConn.Test.NilMissInvoker do
  @moduledoc "An action invoker backed by `GraphConn.Test.NilMissRegistry`."

  use GraphConn.ActionApi.Invoker, request_registry: GraphConn.Test.NilMissRegistry
end
