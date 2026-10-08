if Code.ensure_loaded?(Plug.Cowboy) do
  defmodule GraphConn.Test.EventsMockSocket do
    @moduledoc false

    alias GraphConn.Test.MockSocket
    require Logger

    @behaviour :cowboy_websocket

    @doc false
    @spec init(request :: map(), state :: term()) :: {:cowboy_websocket, map(), map()}
    def init(
          %{headers: %{"sec-websocket-protocol" => "6.1, token-events_" <> client_type}} = request,
          _state
        ) do
      state = %{registry_key: "events_" <> client_type, upgrade_token: "events_" <> client_type}

      {:cowboy_websocket, request, state}
    end

    def init(request, _state) do
      state = %{
        registry_key: request.path,
        upgrade_token: MockSocket.upgrade_token(request)
      }

      {:cowboy_websocket, request, state}
    end

    @doc false
    @spec websocket_init(state :: map()) :: {:ok, map()}
    def websocket_init(state) do
      Registry.TestSockets
      |> Registry.register(state.registry_key, {})

      {:ok, state}
    end

    @doc false
    @spec websocket_handle(frame :: term(), state :: map()) ::
            {:ok, map()} | {:reply, {:text, String.t()}, map()}
    def websocket_handle(:ping, state) do
      Logger.debug("[EventsMockSocket] Received PING")

      {:ok, state}
    end

    def websocket_handle({:text, incoming_message}, state) do
      incoming_message
      |> Jason.decode!(keys: :atoms)
      |> _respond(state)
      |> case do
        {:reply, payload} -> {:reply, {:text, payload}, state}
        _handled -> {:ok, state}
      end
    end

    defp _respond(%{type: "register", args: _args}, _state),
      do: :ok

    defp _respond(%{type: "subscribe", id: _scope_id}, _state),
      do: :ok

    defp _respond(%{type: "token", args: %{_TOKEN: token}}, state),
      do: GraphConn.Mock.put_token_update(:"events-ws", state.upgrade_token, token)

    # To the sender alone, as the Graph does: a broadcast would hand one client another's error.
    defp _respond(msg, _state) do
      response =
        %{"type" => "error", "code" => 400, "message" => "invalid event message #{inspect(msg)}"}
        |> Jason.encode!()

      {:reply, response}
    end

    @doc false
    @spec websocket_info(info :: term(), state :: map()) :: {:reply, {:text, term()}, map()}
    def websocket_info(info, state) do
      {:reply, {:text, info}, state}
    end
  end
end
