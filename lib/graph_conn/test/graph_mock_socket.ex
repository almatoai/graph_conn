if Code.ensure_loaded?(Plug.Cowboy) do
  defmodule GraphConn.Test.GraphMockSocket do
    @moduledoc false

    alias GraphConn.Test.MockSocket
    require Logger

    @behaviour :cowboy_websocket

    @doc false
    @spec init(request :: map(), state :: term()) :: {:cowboy_websocket, map(), map()}
    def init(request, _state) do
      state = %{upgrade_token: MockSocket.upgrade_token(request)}

      {:cowboy_websocket, request, state}
    end

    @doc false
    @spec websocket_handle(frame :: term(), state :: map()) ::
            {:ok, map()} | {:reply, {:text, String.t()}, map()}
    def websocket_handle(:ping, state) do
      Logger.debug("[GraphMockSocket] Received PING")

      {:ok, state}
    end

    def websocket_handle({:text, incoming_message}, state) do
      incoming_message
      |> Jason.decode!(keys: :atoms)
      |> _respond(state)
      |> then(&{:reply, {:text, Jason.encode!(&1)}, state})
    end

    # hiro-graph answers a token update under the request's own id.
    defp _respond(%{type: "token", id: id, _TOKEN: token}, state) do
      :ok = GraphConn.Mock.put_token_update(:"graph-ws", state.upgrade_token, token)
      %{id: id, more: false, body: "ok"}
    end

    defp _respond(msg, _state),
      do: %{error: %{code: 400, message: "invalid graph message #{inspect(msg)}"}}

    @doc false
    @spec websocket_info(info :: term(), state :: map()) :: {:reply, {:text, term()}, map()}
    def websocket_info(info, state),
      do: {:reply, {:text, info}, state}
  end
end
