defmodule GraphConn.Test.MockSocket do
  @moduledoc false

  require Logger

  @behaviour :cowboy_websocket

  @doc false
  @spec init(request :: map(), state :: term()) ::
          {:cowboy_websocket, map(), map()} | {:ok, map(), term()}
  def init(request, state) do
    request
    |> _client_type()
    |> GraphConn.Mock.take_ws_upgrade_rejection()
    |> case do
      {:ok, {status, retry_after_seconds}} -> _reject(request, state, status, retry_after_seconds)
      :error -> _upgrade(request, state)
    end
  end

  # The standalone invoker plays the invoker role for message routing -- the dispatch clauses
  # below key off that -- but keeps its own identity for arming, so the two can be denied apart.
  defp _registry_role("standalone"),
    do: "invoker"

  defp _registry_role(client_type),
    do: client_type

  # Scoped like the auth arm is, so one client's armed rejection cannot refuse another's upgrade.
  defp _client_type(%{
         headers: %{"sec-websocket-protocol" => "0.9, token-action_" <> client_type}
       }),
       do: client_type

  defp _client_type(request),
    do: request.path

  # Answering the upgrade with a plain HTTP response instead of upgrading: returning `{:ok, ...}`
  # from a `:cowboy_websocket` handler's `init/2` means the reply has already been sent.
  defp _reject(request, state, status, retry_after_seconds) do
    Logger.debug("[MockSocket] Rejecting upgrade with #{status}")

    request =
      retry_after_seconds
      |> _reject_headers()
      |> then(&:cowboy_req.reply(status, &1, "", request))

    {:ok, request, state}
  end

  defp _reject_headers(:no_hint),
    do: %{"content-type" => "application/json"}

  defp _reject_headers(retry_after_seconds),
    do: %{"content-type" => "application/json", "retry-after" => to_string(retry_after_seconds)}

  defp _upgrade(
         %{headers: %{"sec-websocket-protocol" => "0.9, token-action_" <> client_type}} = request,
         _state
       ) do
    state = %{
      registry_key: "action_" <> _registry_role(client_type),
      client_type: client_type
    }

    {:cowboy_websocket, request, state}
  end

  defp _upgrade(request, _state) do
    state = %{registry_key: request.path, client_type: request.path}

    {:cowboy_websocket, request, state}
  end

  @doc false
  @spec websocket_init(state :: map()) :: {:ok, map()}
  def websocket_init(state) do
    Registry.TestSockets
    |> Registry.register(state.registry_key, {})

    # Routing shares one key between clients playing the same role; this one names a single
    # client, so a test can close its socket without touching anyone else's.
    Registry.TestSockets
    |> Registry.register({:client, state.client_type}, {})

    {:ok, state}
  end

  @doc false
  @spec websocket_handle(frame :: term(), state :: map()) :: {:ok, map()}
  def websocket_handle(:ping, state) do
    Logger.debug("[MockSocket] Received PING")

    {:ok, state}
  end

  def websocket_handle({:text, incoming_message}, state) do
    incoming_message
    |> Jason.decode!(keys: :atoms)
    |> _respond(state)

    {:ok, state}
  end

  defp _respond(%{type: "acknowledged", id: _id}, _state),
    do: :ok

  defp _respond(%{type: "submitAction", id: id, capability: "nack"}, state) do
    nack =
      %{
        type: "negativeAcknowledged",
        id: id,
        code: 403,
        message: "Forbidden"
      }
      |> Jason.encode!()

    Registry.TestSockets
    |> Registry.dispatch(state.registry_key, fn entries ->
      for {pid, _} <- entries do
        Process.send(pid, nack, [])
      end
    end)
  end

  defp _respond(
         %{type: "submitAction", id: id, capability: capability} = request,
         %{registry_key: "action_invoker"} = state
       ) do
    capabilities = GraphConn.Mock.get_capabilities()

    if capability in Map.keys(capabilities) do
      Registry.TestSockets
      |> Registry.register(id, {})

      1..5
      |> Enum.random()
      |> Process.sleep()

      ack =
        %{
          type: "acknowledged",
          id: id
        }
        |> Jason.encode!()

      _broadcast(state.registry_key, ack)
      _broadcast("action_handler", Jason.encode!(request))
    else
      nack =
        %{
          type: "negativeAcknowledged",
          id: id,
          code: 404,
          message: "capability #{capability} not found"
        }
        |> Jason.encode!()

      _broadcast(state.registry_key, nack)
    end
  end

  defp _respond(
         %{type: "sendActionResult", id: id} = response,
         %{registry_key: "action_handler"} = state
       ) do
    ack =
      %{
        type: "acknowledged",
        id: id
      }
      |> Jason.encode!()

    Registry.TestSockets
    |> Registry.dispatch(state.registry_key, fn entries ->
      for {pid, _} <- entries do
        Process.send(pid, ack, [])
      end
    end)

    Registry.TestSockets
    |> Registry.dispatch(id, fn entries ->
      for {pid, _} <- entries do
        Process.send(pid, Jason.encode!(response), [])
      end
    end)
  end

  defp _respond(msg, state) do
    response =
      %{"type" => "error", "code" => 400, "message" => "invalid action message #{inspect(msg)}"}
      |> Jason.encode!()

    _broadcast(state.registry_key, response)
  end

  defp _broadcast(registry_key, payload) do
    Registry.TestSockets
    |> Registry.dispatch(registry_key, fn entries ->
      Enum.each(entries, fn {pid, _} -> Process.send(pid, payload, []) end)
    end)
  end

  @doc false
  @spec websocket_info(info :: term(), state :: map()) ::
          {:reply, {:text, term()} | {:close, pos_integer(), String.t()}, map()}
  def websocket_info({:close, code, msg}, state),
    do: {:reply, {:close, code, msg}, state}

  def websocket_info(info, state) do
    {:reply, {:text, info}, state}
  end
end
