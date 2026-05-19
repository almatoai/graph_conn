defmodule GraphConn.WsConnections do
  @moduledoc false

  use DynamicSupervisor

  @doc false
  @spec _name(base_name :: atom()) :: module()
  def _name(base_name),
    do: Module.concat(base_name, WsConnections)

  @doc false
  @spec start_link(args :: [atom()]) :: Supervisor.on_start()
  def start_link([base_name]),
    do: DynamicSupervisor.start_link(__MODULE__, :ok, name: _name(base_name))

  @doc false
  @spec start_connection(
          base_name :: atom(),
          api :: atom(),
          config :: Keyword.t(),
          internal_state :: map(),
          version :: map(),
          token :: map()
        ) :: DynamicSupervisor.on_start_child()
  def start_connection(base_name, api, config, internal_state, version, token) do
    spec = {GraphConn.WsConnection, [base_name, api, config, internal_state, version, token]}

    base_name
    |> _name()
    |> DynamicSupervisor.start_child(spec)
  end

  @impl DynamicSupervisor
  @spec init(:ok) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(:ok),
    do: DynamicSupervisor.init(strategy: :one_for_one)
end
