defmodule GraphConn do
  @moduledoc ~S"""
  This module is behaviour that needs to be used in your module which will serve
  as main entrypoint for communication with HIRO Graph server.

  It keeps pool of connections for all REST calls and opens on demand
  websocket connections.

  ## Usage

  ### Define your Conn module


  ```
  defmodule MyConn do
    use GraphConn, otp_app: :graph_conn
    require Logger

    def on_status_change(new_status, _) do
      Logger.debug("New status for main connection is: #{inspect(new_status)}")
    end

    def on_status_change(api, new_status, _) do
      Logger.debug("New status for #{api} connection is: #{inspect(new_status)}")
    end

    def handle_message(api, msg, _) do
      Logger.debug("Received new message #{inspect(msg)} from #{api}")
    end
  end
  ```

  ### Start connection

  Connection can be started either manually or preferably as a part of supervision tree:

  ```
  def start(_, _) do
    children = [
      {MyConn, :from_config},
      # ... other children
    ]

    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end
  ```

  ### Configuration

  Set Graph server details

  ```
  config :graph_conn, MyConn,
    url: "example.com",
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

  ### Invoke call

  Once connection is started, it will pick api versions from Graph server and authenticate
  using `:credentials` from configuration. When everything is ready, `on_status_change/2` callback
  will be invoked with `new_status = :ready`.

  Current connection status can be also checked explicitly:

  ```
  :ready = MyConn.status()
  ```

  Prepare request and execute it against some api (`:action` in this case).

  ```
  config_id = "my_config_id"
  request = %GraphConn.Request{
    path: "app/#{config_id}/handlers"
  }
  {:ok, %GraphConn.Response{} = response} = MyConn.execute(:action, request)
  ```
  """

  @type uuid() :: <<_::288>>
  @type status() :: :got_api_versions | :ready | {:disconnected, any()}
  @type headers() :: [{String.t(), String.t()}]

  defdelegate status(base_name), to: GraphConn.ConnectionManager
  defdelegate execute(base_name, target_api, request), to: GraphConn.ConnectionManager
  defdelegate open_ws_connection(base_name, target_api), to: GraphConn.ConnectionManager

  defdelegate get_client_state(base_name), to: GraphConn.ClientState, as: :get_state
  defdelegate put_client_state(base_name, new_state), to: GraphConn.ClientState, as: :put_state

  @doc false
  defmacro __using__(opts \\ []) do
    quote do
      @behaviour GraphConn
      require Logger

      defp _get_config do
        unquote(opts)
        |> Keyword.get(:otp_app, :graph_conn)
        |> Application.get_env(__MODULE__)
      end

      @doc false
      @spec child_spec(opts :: term()) :: Supervisor.child_spec()
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_supervisor, [opts]},
          type: :supervisor
        }
      end

      @doc """
      Starts supervision tree for handling requests/responses and pushes from HIRO Graph server.
      """
      @spec start_supervisor(
              config :: :from_config | Keyword.t(),
              internal_state :: map()
            ) :: Supervisor.on_start()
      def start_supervisor(config, internal_state \\ %{})

      def start_supervisor(:from_config, internal_state),
        do: _get_config() |> start_supervisor(internal_state)

      def start_supervisor(config, internal_state)
          when is_list(config) and is_map(internal_state),
          do: GraphConn.Supervisor.start_link(__MODULE__, {config, internal_state})

      @doc """
      Stops the supervision tree for this client.
      """
      @spec stop(reason :: term(), timeout :: timeout()) :: :ok
      def stop(reason \\ :normal, timeout \\ :infinity),
        do: GraphConn.Supervisor.stop(__MODULE__, reason, timeout)

      @doc """
      Returns current status of main connection with HIRO Graph server.
      """
      @spec status() :: GraphConn.status()
      def status,
        do: GraphConn.ConnectionManager.status(__MODULE__)

      @doc """
      Sends `message` to `target_api` of HIRO Graph server and returning response back
      """
      @spec execute(target_api :: atom(), request :: GraphConn.Request.t(), opts :: Keyword.t()) ::
              term
      def execute(target_api, %GraphConn.Request{} = request, opts \\ []),
        do: GraphConn.ConnectionManager.execute(__MODULE__, target_api, request, opts)

      # Invokes `fun` function yielding client state to it.
      defp _with_state(fun) do
        {response, new_state} =
          __MODULE__
          |> GraphConn.ClientState.get_state()
          |> fun.()

        :ok = GraphConn.ClientState.put_state(__MODULE__, new_state)
        response
      end

      @before_compile GraphConn
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @impl GraphConn
      def on_status_change(status, _internal_state),
        do: Logger.debug("new main connection status: #{status}")

      @impl GraphConn
      def on_status_change(from_api, status, _internal_state),
        do: Logger.debug("new #{from_api} connection status: #{status}")

      @impl GraphConn
      def handle_message(from_api, msg, _internal_state),
        do: Logger.warning("Received unhandled message from #{from_api}: #{inspect(msg)}")
    end
  end

  @doc """
  This callback is invoked when status of main connection is changed.

  `internal_state` is term that was set as second parameter of `start_supervisor/2`.
  """
  @callback on_status_change(new_status :: atom(), internal_state :: term()) ::
              any()

  @doc """
  This callback is invoked when status of non main connection is changed.

  `internal_state` is term that was set as second parameter of `start_supervisor/2`.
  """
  @callback on_status_change(from_api :: atom(), new_status :: atom(), internal_state :: term()) ::
              any()

  @doc """
  This callback is invoked when there's a new `message` received from Graph server's
  `from_api`.
  """
  @callback handle_message(from_api :: atom(), message :: term(), internal_state :: any()) ::
              :ok | {:ok, response :: term()} | {:error, any()}

  @optional_callbacks on_status_change: 2, on_status_change: 3, handle_message: 3
end
