defmodule GraphConn.ActionApi.Invoker do
  @moduledoc """
  This module is behaviour that should be used in module that will represent
  main entry point for communication with Graph Action API in a role of action invoker,
  meaning it will issue actions and will expect responses back.

  It keeps pool of connections for all REST calls and has one opened websocket connection
  for action-ws api.

  ## Usage

  ### Define your Conn module


  ```
  defmodule ActionInvoker do
    use GraphConn.ActionApi.Invoker, otp_app: :hiro_engine
  end
  ```

  ### Start connection

  Connection can be started either manually or preferably as a part of supervision tree:

  ```
  def start(_, _) do
    children = [
      {ActionInvoker, nil},
      # ... other children
    ]

    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end
  ```

  ### Configuration

  Set Graph server details

  ```
  config :hiro_engine, ActionInvoker,
    host: "example.com",
    port: 8443,
    insecure: true,
    credentials: [
      client_id: "client_id",
      client_secret: "client_secret",
      password: "password%",
      username: "me@arago.de"
    ]
  ```

  For communication with Graph server with REST calls we use pool of connections.

  ### Execute action

  Once connection is started, it will pick api versions from Graph server, authenticate
  using `:credentials` from configuration, get capabilities and applicabilities for this client
  and open WS connection with action-ws api.

  Current REST connection status can be checked explicitly:

  ```
  :ready = ActionInvoker.status()
  ```

  When connection is ready, action can be executed:

  ```
  {:ok, response} = ActionInvoker.execute(ticket_id, action_handler_id, "CapabiltyName", params)

  ```
  """

  @type status() :: :initialized | :ready

  defmodule State do
    @moduledoc false

    @type t() :: %__MODULE__{
            capabilities: [any()],
            status: GraphConn.ActionApi.Invoker.status(),
            ws_status: GraphConn.ActionApi.Invoker.status()
          }

    defstruct capabilities: [], status: :initialized, ws_status: :initialized
  end

  @doc false
  defmacro __using__(opts \\ []) do
    quote location: :keep do
      use Supervisor
      @behaviour GraphConn
      alias GraphConn.ActionApi
      alias GraphConn.ActionApi.Invoker.RequestRegistry
      alias GraphConn.ActionApi.Invoker.State, as: InvokerState
      alias GraphConn.ActionApi.Invoker.RequestRegistry.Local, as: LocalRequestRegistry
      require Logger

      @ack_timeout 3_000
      @number_of_request_retries 3
      @request_registry Keyword.get(
                          unquote(opts),
                          :request_registry,
                          LocalRequestRegistry
                        )

      if @request_registry == LocalRequestRegistry do
        @impl Supervisor
        def init(config) do
          [
            {LocalRequestRegistry, __MODULE__},
            {GraphConn.Supervisor, [__MODULE__, {config, %InvokerState{}}]}
          ]
          |> Supervisor.init(strategy: :one_for_all)
        end
      else
        @impl Supervisor
        def init(config) do
          [
            {GraphConn.Supervisor, [__MODULE__, {config, %InvokerState{}}]}
          ]
          |> Supervisor.init(strategy: :one_for_all)
        end
      end

      defp _get_config do
        unquote(opts)
        |> Keyword.get(:otp_app, :graph_conn)
        |> Application.get_env(__MODULE__)
      end

      def start_link(config \\ nil) do
        Supervisor.start_link(__MODULE__, config || _get_config(), name: __MODULE__)
      end

      @doc """
      Returns current status of main (REST) connection with HIRO Graph server.
      """
      @spec status() :: GraphConn.status()
      def status,
        do: GraphConn.status(__MODULE__)

      # Invokes `fun` function yielding client state to it.
      defp with_state(fun) do
        {response, new_state} =
          __MODULE__
          |> GraphConn.get_client_state()
          |> fun.()

        :ok = GraphConn.put_client_state(__MODULE__, new_state)
        response
      end

      @impl GraphConn
      @doc false
      # get capabilities and applicabilities only when invoker was just :initialized and connection status is :ready now.
      def on_status_change(:ready, %InvokerState{status: :initialized} = state) do
        %{}
        |> _inject_capabilities()
        |> _inject_applicabilities()
        |> _open_ws_connection()
        |> case do
          %{capabilities: _, applicabilities: _} = token ->
            new_state =
              state
              |> Map.put(:status, :ready)
              |> Map.merge(token)

            with_state(fn
              %InvokerState{} -> {:ok, new_state}
            end)

            # question is what shall we do if we couldn't fetch both capabilities and applicabilities?
            # if we leave it unmatched Invoker conn will crash and will be restarted...
        end
      end

      def on_status_change(new_status, %InvokerState{status: current_status} = state) do
        Logger.debug(
          "[ActionInvoker] Unhandled ActionAPI status change from #{current_status} to #{new_status}"
        )
      end

      @impl GraphConn
      @doc false
      def on_status_change(:"action-ws", status, %InvokerState{ws_status: :initialized} = state) do
        with_state(fn
          %InvokerState{} -> {:ok, %{state | ws_status: status}}
        end)
      end

      def on_status_change(
            :"action-ws",
            new_status,
            %InvokerState{status: current_status} = state
          ) do
        Logger.debug(
          "[ActionInvoker] Unhandled Action WS connection status change from #{current_status} to #{inspect(new_status)}"
        )
      end

      @impl GraphConn
      @doc false
      def handle_message(:"action-ws", %{"type" => "acknowledged"} = msg, %InvokerState{}),
        do: RequestRegistry.ack(__MODULE__, msg["id"], @request_registry)

      def handle_message(
            :"action-ws",
            %{"type" => "negativeAcknowledged"} = msg,
            %InvokerState{}
          ),
          do:
            RequestRegistry.nack(
              __MODULE__,
              msg["id"],
              %{
                code: msg["code"],
                message: msg["message"]
              },
              @request_registry
            )

      def handle_message(:"action-ws", %{"type" => "sendActionResult"} = msg, %InvokerState{}) do
        result = Jason.decode!(msg["result"])
        RequestRegistry.respond(__MODULE__, msg["id"], result, @request_registry)

        Logger.debug("[ActionInvoker] Acking response", req_id: msg["id"])

        ack = %{type: "acknowledged", id: msg["id"], code: 200}

        :ok =
          GraphConn.execute(__MODULE__, :"action-ws", %GraphConn.Request{
            body: ack
          })
      end

      def handle_message(:"action-ws", %{"type" => "configChanged"} = msg, %InvokerState{}),
        do: on_config_changed()

      def handle_message(:"action-ws", msg, %InvokerState{}) do
        Logger.error(
          "[ActionInvoker] Received unexpected message from action-ws: #{inspect(msg)}"
        )
      end

      @doc """
      Returns capabilities that are available for this client
      """
      @spec available_capabilities ::
              %{(capability :: String.t()) => map()}
              | {:error, {:connection_not_ready, ActionApi.execution_error()}}
      def available_capabilities,
        do: _state_of(fn state -> state.capabilities end)

      @doc """
      Returns applicabilities that are available for this client
      """
      @spec available_applicabilities ::
              %{(handler_name :: String.t()) => map()}
              | {:error, {:connection_not_ready, ActionApi.execution_error()}}
      def available_applicabilities,
        do: _state_of(fn state -> state.applicabilities end)

      @spec _state_of((State.t() -> response :: any())) ::
              response ::
              %{String.t() => map()}
              | {:error, {:connection_not_ready, ActionApi.execution_error()}}
      defp _state_of(fun) do
        with_state(fn
          %InvokerState{status: :ready} = state ->
            {fun.(state), state}

          %InvokerState{status: status} = state ->
            {{:error, {:connection_not_ready, status}}, state}
        end)
      end

      @doc """
      Returns map of field names and their defaults for given `capability_name`.

      For unknown `capability_name` it returns empty map.
      """
      @spec capability_defaults(String.t()) :: %{String.t() => any()}
      def capability_defaults(capability_name) do
        case available_capabilities() do
          %{} = capabilities ->
            empty_capability = %{"mandatoryParameters" => %{}, "optionalParameters" => %{}}
            capability = Map.get(capabilities, capability_name, empty_capability)

            for {field, %{"default" => value}} <-
                  Map.merge(capability["mandatoryParameters"], capability["optionalParameters"]) do
              {field, value}
            end
            |> Enum.into(%{})

          {:error, {:connection_not_ready, _}} ->
            %{}
        end
      end

      def reconfigure do
        Logger.info("[ActionInvoker] Reconfiguring...")

        with_state(fn
          %InvokerState{} = state ->
            new_state =
              %{}
              |> _inject_capabilities()
              |> _inject_applicabilities()
              |> case do
                %{capabilities: _, applicabilities: _} = token ->
                  Map.merge(state, token)
              end

            {:ok, new_state}
        end)
      end

      @doc """
      Executes action on `action_handler_id` for given `ticket_id` and `capability_name`
      with provided `params` and returing either result from action handler or
      some error message.

      IMPORTANT! If "timeout" is provided in params it MUST be in seconds (since
      defaults are in seconds).
      """
      @spec execute(String.t(), String.t(), String.t(), map(), Keyword.t()) ::
              :ok
              | {:ok, response :: any()}
              | {:error, req_id :: String.t(), ActionApi.execution_error()}
      def execute(ticket_id, action_handler_id, capability_name, %{} = params, opts \\ []) do
        Logger.debug("Trying to send: #{params["req"]}")
        ack_timeout = Keyword.get(opts, :ack_timeout, @ack_timeout)

        params =
          params
          |> Enum.map(fn {key, val} -> {to_string(key), val} end)
          |> Enum.into(%{})
          |> _inject_defaults(capability_name)

        timeout =
          case params["timeout"] do
            timeout when is_binary(timeout) -> String.to_integer(timeout) * 1_000
            timeout when is_integer(timeout) -> timeout * 1_000
            other -> nil
          end

        params = Map.put(params, "timeout", timeout)

        request =
          %ActionApi.Request{id: request_id} =
          ActionApi.Request.new(%{
            ticket_id: ticket_id,
            handler: action_handler_id,
            capability: capability_name,
            params: params,
            timeout: Keyword.get(opts, :timeout, timeout)
          })

        Logger.metadata(req_id: request_id)

        Logger.info(
          "[ActionInvoker] Executing #{capability_name} on #{action_handler_id} with params #{inspect(params)}"
        )

        try do
          :ok = RequestRegistry.register(__MODULE__, request_id, @request_registry)

          _execute(request, ack_timeout)
        after
          RequestRegistry.unregister(__MODULE__, request_id, @request_registry)
        end
      end

      defp _inject_defaults(params, capability_name) do
        capability_name
        |> capability_defaults()
        |> Map.merge(params)
      end

      @spec _execute(ActionApi.Request.t(), pos_integer(), pos_integer()) ::
              :ok
              | {:ok, response :: any()}
              | {:error, request_id :: String.t(), ActionApi.execution_error()}
      defp _execute(request, ack_timeout, attempt \\ 1, last_call? \\ false)

      defp _execute(%ActionApi.Request{} = request, ack_timeout, attempt, _)
           when attempt > @number_of_request_retries,
           do: {:error, request.id, {:ack_timeout, ack_timeout * @number_of_request_retries}}

      defp _execute(
             %ActionApi.Request{id: request_id} = request,
             ack_timeout,
             attempt,
             last_call?
           ) do
        Logger.info("[ActionInvoker] Sending request to server")

        :ok =
          GraphConn.execute(__MODULE__, :"action-ws", %GraphConn.Request{
            body: request
          })

        Logger.debug("[ActionInvoker] Waiting ack")

        receive do
          {:ack, ^request_id} ->
            Logger.info("[ActionInvoker] Ack received")

            timeout =
              if last_call?,
                do: 0,
                else: request.timeout

            request_id
            |> _wait_for_response(request.timeout)
            |> case do
              {:error, ^request_id, {:exec_timeout, _}} ->
                if last_call? do
                  Logger.error("[ActionInvoker] Response timeout.")
                  {:error, request_id, {:exec_timeout, request.timeout}}
                else
                  Logger.warning("[Invoker] Sending last call")
                  _execute(request, ack_timeout, 1, true)
                end

              response ->
                response
            end

          {:nack, ^request_id, %{code: 404} = error} ->
            {:error, request_id, {:nack, error}}

          {:nack, ^request_id, error} ->
            Logger.error("[ActionInvoker] Message nacked: #{inspect(error)}")
            {:error, request_id, {:nack, error}}
        after
          ack_timeout ->
            Logger.warning("[ActionInvoker] Message ack timeout after: #{ack_timeout}ms")
            _execute(request, ack_timeout, attempt + 1, last_call?)
        end
      end

      defp _wait_for_response(request_id, timeout) do
        Logger.debug("[ActionInvoker] Waiting response")

        receive do
          {:response, ^request_id, response} ->
            Logger.info("[ActionInvoker] Response received")

            case response do
              %{"error" => "exec_timeout"} ->
                {:error, request_id, {:handler_returned_timeout, timeout}}

              %{"error" => "request_timed_out", "last_status" => last_status} ->
                {:error, request_id, {:action_api_returned_timeout, last_status}}

              %{"error" => error} ->
                {:error, request_id, error}

              _ ->
                {:ok, response}
            end
        after
          timeout + 1_000 ->
            {:error, request_id, {:exec_timeout, timeout}}
        end
      end

      @spec _inject_capabilities(map()) :: map()
      defp _inject_capabilities(%{} = token) do
        request = %GraphConn.Request{path: "capabilities"}

        case GraphConn.execute(__MODULE__, :action, request) do
          {:ok, %GraphConn.Response{code: 200, body: body}} ->
            Map.put(token, :capabilities, body)

          other ->
            Logger.error("[ActionInvoker] Can't get capabilities: #{inspect(other)}")
            token
        end
      end

      @spec _inject_applicabilities(map()) :: map()
      defp _inject_applicabilities(%{capabilities: _} = token) do
        request = %GraphConn.Request{path: "applicabilities"}

        case GraphConn.execute(__MODULE__, :action, request) do
          {:ok, %GraphConn.Response{code: 200, body: body}} ->
            Map.put(token, :applicabilities, body)

          other ->
            Logger.error("[ActionInvoker] Can't get applicabilities: #{inspect(other)}")
            token
        end
      end

      defp _inject_applicabilities(%{} = token),
        do: token

      defp _open_ws_connection(%{applicabilities: _} = token) do
        :ok = GraphConn.open_ws_connection(__MODULE__, :"action-ws")
        token
      end

      defp _open_ws_connection(%{} = token),
        do: token

      @spec on_config_changed() :: any()
      def on_config_changed,
        do: Logger.warning("[ActionInvoker] Received unhandled configChanged message")

      defoverridable on_config_changed: 0
    end
  end
end
