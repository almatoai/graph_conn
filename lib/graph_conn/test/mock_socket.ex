if Code.ensure_loaded?(Plug.Cowboy) do
  defmodule GraphConn.Test.MockSocket do
    @moduledoc false

    require Logger

    @behaviour :cowboy_websocket

    @doc false
    @spec init(request :: map(), state :: term()) ::
            {:cowboy_websocket, map(), map()}
            | {:cowboy_websocket, map(), map(), map()}
            | {:ok, map(), term()}
    def init(request, state) do
      request
      |> _client_type()
      |> GraphConn.Mock.take_ws_upgrade_rejection()
      |> case do
        {:ok, {status, retry_after_seconds}} ->
          _reject(request, state, status, retry_after_seconds)

        :error ->
          request
          |> _client_type()
          |> GraphConn.Mock.ws_upgrade_delay()
          |> Process.sleep()

          _upgrade(request, state)
      end
    end

    @doc false
    @spec upgrade_token(request :: map()) :: String.t() | nil
    def upgrade_token(%{headers: %{"sec-websocket-protocol" => protocols}}) do
      protocols
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.find_value(fn
        "token-" <> token -> token
        _other_protocol -> nil
      end)
    end

    def upgrade_token(_request),
      do: nil

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
         do: GraphConn.Mock.base_token(client_type)

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
           %{headers: %{"sec-websocket-protocol" => "0.9, token-action_" <> client_type}} =
             request,
           _state
         ) do
      client_type = GraphConn.Mock.base_token(client_type)

      state = %{
        registry_key: "action_" <> _registry_role(client_type),
        client_type: client_type,
        upgrade_token: upgrade_token(request)
      }

      {:cowboy_websocket, request, state, _websocket_opts(client_type)}
    end

    defp _upgrade(request, _state) do
      state = %{
        registry_key: request.path,
        client_type: request.path,
        upgrade_token: upgrade_token(request)
      }

      {:cowboy_websocket, request, state}
    end

    # Enforces the limit its hello advertises, as the server does, or cowboy's own 1_000_000.
    defp _websocket_opts(client_type) do
      client_type
      |> GraphConn.Mock.hello_max_frame_bytes()
      |> case do
        nil -> %{max_frame_size: 1_000_000}
        max_frame_bytes -> %{max_frame_size: max_frame_bytes}
      end
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

      :ok = GraphConn.Mock.put_ws_upgrade(:"action-ws", state.upgrade_token)
      send(self(), _hello(state.client_type))
      {:ok, state}
    end

    defp _hello(client_type) do
      client_type
      |> GraphConn.Mock.hello_max_frame_bytes()
      |> case do
        nil -> %{type: "hello"}
        max_frame_bytes -> %{type: "hello", max_frame_bytes: max_frame_bytes}
      end
      |> Jason.encode!()
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

    defp _respond(%{type: "clientHello"} = client_hello, state),
      do: GraphConn.Mock.put_client_hello(state.client_type, client_hello)

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
           %{registry_key: "action_invoker", client_type: client_type} = state
         ) do
      client_type
      |> GraphConn.Mock.take_request_denial()
      |> case do
        {:ok, retry_after_ms} -> _deny(state, id, retry_after_ms)
        :error -> _submit(request, id, capability, state)
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

    defp _submit(request, id, capability, state) do
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

    # What a rate-limiting gateway answers on the open socket: an error frame carrying the client's
    # own id, in place of the ack.
    defp _deny(state, id, retry_after_ms) do
      %{
        "error" => %{
          "code" => 429,
          "message" => "Rate limit exceeded",
          "retryAfterMs" => retry_after_ms
        },
        "id" => id
      }
      |> Jason.encode!()
      |> then(&_broadcast(state.registry_key, &1))
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
end
