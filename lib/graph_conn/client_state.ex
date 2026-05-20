defmodule GraphConn.ClientState do
  @moduledoc """
  Keeps state of client conn module.
  """

  use GenServer

  defp _name(base_name),
    do: Module.concat(base_name, ClientState)

  @doc false
  @spec child_spec(opts :: [atom() | map()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, opts},
      type: :worker
    }
  end

  @doc false
  @spec start_link(base_name :: atom(), state :: map()) :: GenServer.on_start()
  def start_link(base_name, state) do
    GenServer.start_link(__MODULE__, state, name: _name(base_name))
  end

  @doc "Returns the current state of the client conn module."
  @spec get_state(base_name :: atom()) :: map()
  def get_state(base_name) do
    base_name
    |> _name()
    |> GenServer.call(:get_state)
  end

  @doc "Replaces the stored state with `new_state`."
  @spec put_state(base_name :: atom(), new_state :: map()) :: :ok
  def put_state(base_name, new_state) do
    base_name
    |> _name()
    |> GenServer.cast({:put_state, new_state})

    :ok
  end

  @impl GenServer
  def init(state),
    do: {:ok, state}

  @impl GenServer
  def handle_call(:get_state, _from, state),
    do: {:reply, state, state}

  @impl GenServer
  def handle_cast({:put_state, new_state}, _state),
    do: {:noreply, new_state}
end
