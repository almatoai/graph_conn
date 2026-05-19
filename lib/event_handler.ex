defmodule GraphConn.EventHandler do
  @moduledoc """
  event websocket handler behaviour
  """

  @callback default_execution_timeout(String.t()) :: non_neg_integer()
  @callback resend_response_timeout() :: non_neg_integer()
  @callback handle_event(event :: %{String.t() => any}) :: {:ok, term()} | {:error, term()}
  @callback register() ::
              :ok
              | {:ok, GraphConn.Response.t()}
              | {:error, GraphConn.ResponseError.t()}
              | {:error, {:unknown_api, [any()]}}

  defmacro __using__(opts \\ []) do
    quote location: :keep do
      use Supervisor
      @behaviour GraphConn
      @behaviour GraphConn.EventHandler
      require Logger

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
      @spec _request_cache_name() :: module()
      def _request_cache_name,
        do: Module.concat(__MODULE__, RequestCache)

      @doc "Starts the event handler supervision tree."
      @spec start_link(config :: nil | Keyword.t()) :: Supervisor.on_start()
      def start_link(config \\ nil) do
        Supervisor.start_link(__MODULE__, _put_config(config), name: __MODULE__)
      end

      @impl Supervisor
      def init(config) do
        children = [
          {GraphConn.Supervisor, [__MODULE__, {config, %{}}]}
        ]

        Supervisor.init(children, strategy: :one_for_one, max_restarts: 1)
      end

      @doc """
      Returns current status of main (REST) connection with HIRO Graph server.
      """
      @spec status() :: GraphConn.status()
      def status,
        do: GraphConn.status(__MODULE__)

      @impl GraphConn
      @doc false
      def on_status_change(:ready, internal_state),
        do: :ok = GraphConn.open_ws_connection(__MODULE__, :"events-ws")

      def on_status_change(_, internal_state),
        do: :ok

      @impl GraphConn
      @doc false
      def on_status_change(:"events-ws", :ready, internal_state) do
        Logger.info("[EventHandler] New EventWS status: :ready}")
        register()
        subscribe()
      end

      @impl GraphConn
      @doc false
      def handle_message(
            :"events-ws",
            %{
              "type" => "closeConnection",
              "reason" => reason
            } = msg,
            _
          ) do
        Logger.info("[EventHandler] Received close connection request: #{inspect(reason)}")
        {:close, reason}
      end

      def handle_message(
            :"events-ws",
            %{
              "type" => _type,
              "body" => _body
            } = event,
            _
          ) do
        Logger.debug("[EventHandler] Received event: #{inspect(event)}")
        handle_event(event)
      end

      def handle_message(:"events-ws", msg, internal_state),
        do: handle_message_default(:"events-ws", msg, internal_state)

      @doc false
      def handle_event_default(msg), do: handle_message_default(:"events-ws", msg, nil)

      @doc false
      def handle_message_default(:"events-ws", msg, _) do
        Logger.warning(
          "[EventHandler] Received unexpected message from events-ws: #{inspect(msg)}"
        )
      end

      @doc "Sends a `register` message to the events-ws upstream with `args` as the filter."
      def register(args) do
        GraphConn.execute(__MODULE__, :"events-ws", %GraphConn.Request{
          body: %{
            type: "register",
            args: args
          }
        })
      end

      @doc "Sends a `subscribe` message to the events-ws upstream using the configured `scope_id`."
      def subscribe do
        GraphConn.execute(__MODULE__, :"events-ws", %GraphConn.Request{
          body: %{
            type: "subscribe",
            id: _get_config()[:scope_id]
          }
        })
      end

      @doc false
      def default_execution_timeout(_event),
        do: 60_000

      @doc false
      def resend_response_timeout,
        do: 3_000

      @doc false
      def handle_event(event) do
        Logger.warning("[EventHandler] Unhandled event message: #{event}")
        {:ok, :ignored}
      end

      defoverridable default_execution_timeout: 1, resend_response_timeout: 0, handle_event: 1
    end
  end
end
