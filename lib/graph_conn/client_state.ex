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

  # Replaces the stored state with the one `fun` returns for it and returns `fun`'s reply, in one
  # step. `fun` runs inside this process, so it must not call ClientState or the connection
  # manager; whatever it raises, throws or exits with fails the caller, not this process.
  @doc false
  @spec update_state(base_name :: atom(), fun :: (map() -> {reply, map()})) :: reply
        when reply: term()
  def update_state(base_name, fun) do
    base_name
    |> _name()
    |> GenServer.call({:update_state, fun})
    |> case do
      {:updated, reply} -> reply
      {:failed, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  @impl GenServer
  def init(state),
    do: {:ok, state}

  @impl GenServer
  def handle_call(:get_state, _from, state),
    do: {:reply, state, state}

  def handle_call({:update_state, fun}, _from, state) do
    {reply, new_state} = fun.(state)
    {:reply, {:updated, reply}, new_state}
  catch
    kind, reason -> {:reply, {:failed, kind, reason, __STACKTRACE__}, state}
  end

  @impl GenServer
  def handle_cast({:put_state, new_state}, _state),
    do: {:noreply, new_state}
end
