defmodule GraphConn.Supervisor do
  @moduledoc false
  use Supervisor
  alias GraphConn.Tools

  @doc false
  @spec child_spec(args :: [atom() | Keyword.t()]) :: Supervisor.child_spec()
  def child_spec([base_name, config]) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [base_name, config]}
    }
  end

  @doc false
  @spec start_link(base_name :: atom(), config_and_state :: {Keyword.t(), map()}) ::
          Supervisor.on_start()
  def start_link(base_name, {config, internal_state}) do
    Supervisor.start_link(__MODULE__, {base_name, config, internal_state}, name: _name(base_name))
  end

  @doc false
  @spec stop(base_name :: atom(), reason :: term(), timeout :: timeout()) :: :ok
  def stop(base_name, reason, timeout) do
    base_name
    |> _name()
    |> Supervisor.stop(reason, timeout)
  end

  @impl true
  def init({base_name, config, internal_state}) do
    [
      {GraphConn.ClientState, [base_name, internal_state]},
      {GraphConn.WsConnections, [base_name]},
      {Finch,
       name: Module.concat(base_name, Finch),
       pools: %{
         default: [{:size, 50}, {:count, 1} | _conn_opts()]
       }},
      {GraphConn.ConnectionManager, [base_name, config]}
    ]
    |> Supervisor.init(strategy: :one_for_all)
  end

  defp _name(base_name), do: Module.concat(base_name, Supervisor)

  defp _conn_opts do
    insecure? = Application.get_env(:graph_conn, :insecure) == true
    proxy = Application.get_env(:graph_conn, :proxy, false)

    if ca_cert_file = Application.get_env(:graph_conn, :ca_cert),
      do: :public_key.cacerts_load(ca_cert_file)

    case {insecure?, proxy} do
      {true, false} ->
        transport_opts = [verify: :verify_none]
        [conn_opts: [transport_opts: transport_opts]]

      {true, proxy} ->
        transport_opts = [verify: :verify_none]
        [conn_opts: [transport_opts: transport_opts, proxy: _proxy_opts(proxy)]]

      {false, false} ->
        [conn_opts: [transport_opts: _tls_transport_opts()]]

      {false, proxy} ->
        [conn_opts: [transport_opts: _tls_transport_opts(), proxy: _proxy_opts(proxy)]]
    end
  end

  defp _tls_transport_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      reuse_sessions: false
    ]
  end

  defp _proxy_opts(config) do
    address = Keyword.fetch!(config, :address)
    port = config |> Keyword.fetch!(:port) |> Tools.to_integer()
    opts = Keyword.get(config, :opts, [])

    {:http, address, port, opts}
  end
end
