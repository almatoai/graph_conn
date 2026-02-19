defmodule GraphConn.Test.EventsMockSocket do
  @moduledoc false

  require Logger

  @behaviour :cowboy_websocket

  def init(
        %{headers: %{"sec-websocket-protocol" => "6.1, token-events_" <> client_type}} = request,
        _state
      ) do
    state = %{registry_key: "events_" <> client_type}

    {:cowboy_websocket, request, state}
  end

  def init(request, _state) do
    state = %{registry_key: request.path}

    {:cowboy_websocket, request, state}
  end

  def websocket_init(state) do
    Registry.TestSockets
    |> Registry.register(state.registry_key, {})

    {:ok, state}
  end

  def websocket_handle(:ping, state) do
    Logger.debug("[EventsMockSocket] Received PING")

    {:ok, state}
  end

  def websocket_handle({:text, incoming_message}, state) do
    incoming_message
    |> Jason.decode!(keys: :atoms)
    |> _respond(state)

    {:ok, state}
  end

  defp _respond(%{type: "register", args: _args}, _state),
    do: :ok

  defp _respond(%{type: "subscribe", id: _scope_id}, _state),
    do: :ok

  defp _respond(msg, state) do
    response =
      %{"type" => "error", "code" => 400, "message" => "invalid event message #{inspect(msg)}"}
      |> Jason.encode!()

    Registry.TestSockets
    |> Registry.dispatch(state.registry_key, fn entries ->
      for {pid, _} <- entries, do: Process.send(pid, response, [])
    end)
  end

  def websocket_info(info, state) do
    {:reply, {:text, info}, state}
  end
end
