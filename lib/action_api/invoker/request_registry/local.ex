defmodule GraphConn.ActionApi.Invoker.RequestRegistry.Local do
  @moduledoc """
  In-process `Registry`-backed implementation of `RequestRegistry`.

  Maps request ids to the caller pid awaiting the response. Default registry
  used when no distributed implementation is configured.
  """

  alias GraphConn.ActionApi.Invoker.RequestRegistry
  @behaviour RequestRegistry

  @doc false
  @spec child_spec(arg :: atom()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]}
    }
  end

  @doc false
  @spec start_link(base_name :: atom()) :: GenServer.on_start()
  def start_link(base_name) do
    Registry.start_link(
      keys: :duplicate,
      name: RequestRegistry.name(base_name),
      partitions: System.schedulers_online()
    )
  end

  @impl RequestRegistry
  @spec register_self(name :: atom(), request_id :: term()) :: :ok
  def register_self(name, request_id) do
    {:ok, _pid} = Registry.register(name, request_id, [])
    :ok
  end

  @impl RequestRegistry
  @spec lookup(name :: atom(), request_id :: term()) :: [pid()]
  def lookup(name, request_id) do
    name
    |> Registry.lookup(request_id)
    |> Enum.map(fn {pid, _value} -> pid end)
  end

  @impl RequestRegistry
  @spec unregister(name :: atom(), request_id :: term()) :: :ok
  def unregister(name, request_id),
    do: Registry.unregister(name, request_id)
end
