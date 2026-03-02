if Code.ensure_loaded?(Cachex) do
  defmodule GraphConn.ActionApi.Handler do
    @moduledoc """
    This module is behaviour that should be used in module that will represent
    main entry point for communication with Graph Action API in a role of action handler,
    meaning it will receive action requests, execute them agains environment and return response back.
    """

    @callback default_execution_timeout(String.t()) :: non_neg_integer()
    @callback resend_response_timeout() :: non_neg_integer()
    @callback execute(
                req_id :: String.t(),
                capability :: String.t(),
                params :: %{String.t() => any}
              ) ::
                {:ok, term()} | {:error, term()}

    defmacro __using__(opts \\ []) do
      quote location: :keep do
        use Supervisor
        @behaviour GraphConn
        @behaviour GraphConn.ActionApi.Handler
        alias GraphConn.ActionApi
        require Logger
        require Cachex.Spec

        defp _get_config do
          unquote(opts)
          |> Keyword.get(:otp_app, :graph_conn)
          |> Application.get_env(__MODULE__)
        end

        defp _put_config(nil), do: _get_config()
        defp _put_config([]), do: _get_config()

        defp _put_config(config) do
          unquote(opts)
          |> Keyword.get(:otp_app, :graph_conn)
          |> Application.put_env(__MODULE__, config)

          config
        end

        @doc false
        @spec _task_supervisor_name() :: module()
        def _task_supervisor_name(),
          do: Module.concat(__MODULE__, TaskSupervisor)

        @doc false
        @spec _request_cache_name() :: module()
        def _request_cache_name(),
          do: Module.concat(__MODULE__, RequestCache)

        def start_link(config \\ nil) do
          Supervisor.start_link(__MODULE__, _put_config(config), name: __MODULE__)
        end

        @impl Supervisor
        def init(config) do
          children = [
            {Cachex,
             [
               name: _request_cache_name(),
               expiration:
                 Cachex.Spec.expiration(
                   # default record expiration
                   default: :timer.minutes(60),
                   # how often cleanup should occur
                   interval: :timer.seconds(60)
                 )
             ]},
            {GraphConn.Supervisor, [__MODULE__, {config, %{}}]},
            {Task.Supervisor, [name: _task_supervisor_name()]},
            {ActionApi.Responder, __MODULE__}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end

        @doc """
        Returns current status of main (REST) connection with HIRO Graph server.
        """
        @spec status() :: GraphConn.status()
        def status,
          do: GraphConn.status(__MODULE__)

        @impl GraphConn
        @doc false
        def on_status_change(:ready, _),
          do: :ok = GraphConn.open_ws_connection(__MODULE__, :"action-ws")

        def on_status_change(new_status, _),
          do:
            Logger.debug("[ActionHandler] New ActionAPI status changed to #{inspect(new_status)}")

        @impl GraphConn
        @doc false
        def on_status_change(:"action-ws", status, _),
          do: Logger.info("[ActionHandler] New ActionWS status: #{inspect(status)}")

        @impl GraphConn
        @doc false
        def handle_message(:"action-ws", %{"type" => "acknowledged", "id" => req_id} = _msg, _),
          do: ActionApi.Responder.response_acked(__MODULE__, req_id)

        def handle_message(
              :"action-ws",
              %{"type" => "negativeAcknowledged", "id" => req_id} = _msg,
              _
            ) do
          Logger.warning("[ActionHandler] Server returned NACK", req_id: req_id)
          ActionApi.Responder.response_acked(__MODULE__, req_id)
        end

        def handle_message(
              :"action-ws",
              %{
                "type" => "submitAction",
                "id" => req_id,
                "capability" => capability,
                "parameters" => params
              } = msg,
              _
            ) do
          Logger.debug("[ActionHandler] Received message: #{inspect(msg)}")

          task_fun = _task(req_id, capability, params)

          execution_timeout = msg["timeout"] || default_execution_timeout(capability)

          Task.Supervisor.start_child(_task_supervisor_name(), task_fun,
            shutdown: execution_timeout + 500
          )
        end

        # def handle_message(
        #      :"action-ws",
        #      %{
        #        "type" => "closeConnection",
        #        "reason" => reason
        #      } = msg,
        #      _
        #    ) do
        #  Logger.info("[ActionHandler] Received close connection request: #{inspect(reason)}")
        #  {:close, reason}
        # end

        def handle_message(:"action-ws", msg, _) do
          Logger.warning(
            "[ActionHandler] Received unexpected message from action-ws: #{inspect(msg)}"
          )
        end

        defp _task(req_id, capability, params) do
          fn ->
            Logger.metadata(req_id: req_id)

            task_pid = self()

            _request_cache_name()
            |> Cachex.transaction([req_id], fn worker ->
              worker
              |> Cachex.get(req_id)
              |> case do
                {:ok, nil} ->
                  Cachex.put(worker, req_id, {:in_progress, []})
                  :execute_action

                {:ok, {:in_progress, waiting_tasks}} ->
                  Cachex.put(worker, req_id, {:in_progress, [task_pid | waiting_tasks]})
                  :wait

                {:ok, response} ->
                  response
              end
            end)
            |> tap(fn _ ->
              GraphConn.execute(__MODULE__, :"action-ws", %GraphConn.Request{
                body: %{id: req_id, type: "acknowledged", code: 200, message: ""}
              })
            end)
            |> case do
              {:ok, :execute_action} ->
                response = _execute_action(req_id, capability, params)
                _set_response(req_id, response)

              {:ok, :wait} ->
                Logger.info("The same request is already processing. Wait for the response...")
                _wait_for_response(req_id)

              {:ok, response} ->
                Logger.info("Cache hit. Returning cached response...")
                _respond_with(req_id, response)
            end
          end
        end

        defp _set_response(req_id, response) do
          {:ok, other_waiting_tasks} =
            _request_cache_name()
            |> Cachex.transaction([req_id], fn worker ->
              {:ok, {:in_progress, other_waiting_tasks}} = Cachex.get(worker, req_id)
              Cachex.put(worker, req_id, response)
              other_waiting_tasks
            end)

          case other_waiting_tasks do
            [] ->
              # If noone is waiting for response, return result from this task
              _respond_with(req_id, response)

            [latest_waiting_task | other_waiting_tasks] ->
              # Latest task should get result back, others can be ignored
              send(latest_waiting_task, {:response, req_id, response})

              for task <- other_waiting_tasks,
                  do: send(task, {:response, req_id, :ignore})
          end
        end

        defp _wait_for_response(req_id) do
          receive do
            {:response, ^req_id, :ignore} ->
              :ok

            {:response, ^req_id, response} ->
              _respond_with(req_id, response)
          end
        end

        defp _respond_with(req_id, response) do
          Logger.info("[ActionHandler] Sending result")

          %GraphConn.Request{
            body: %{id: req_id, type: "sendActionResult", result: response}
          }
          |> ActionApi.Responder.return_response(__MODULE__, resend_response_timeout())
        end

        defp _execute_action(req_id, capability, params) do
          Logger.info("[ActionHandler] Executing #{inspect(capability)}: #{inspect(params)}")

          req_id
          |> execute(capability, params)
          |> case do
            {:ok, response} ->
              Jason.encode!(response)

            {:error, error} ->
              case Jason.encode(%{error: error}) do
                {:ok, json} -> json
                _ -> Jason.encode!(%{error: inspect(error)})
              end
          end
        end

        def default_execution_timeout(_capability),
          do: 60_000

        def resend_response_timeout,
          do: 3_000

        def execute(_req_id, capability, _params) do
          Logger.warning("[ActionHandler] Unhandled capability received: #{capability}")
          {:error, %{code: 404, message: "Unhandled capability #{inspect(capability)}"}}
        end

        defoverridable default_execution_timeout: 1, resend_response_timeout: 0, execute: 3
      end
    end
  end
end
