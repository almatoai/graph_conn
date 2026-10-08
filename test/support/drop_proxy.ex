defmodule GraphConn.Test.DropProxy do
  @moduledoc """
  A TCP proxy in front of the mock server that can silently drop the flows it carries.

  A dropped flow keeps the client's socket open, so no FIN reaches it, closes the upstream, and
  answers the client's next bytes with an RST: what a middlebox that expired an idle flow does.
  Flows accepted after a drop are carried normally.
  """

  use GenServer

  @doc "Starts the proxy on a free port, forwarding to `upstream_port` on localhost."
  @spec start_link(upstream_port :: :inet.port_number()) :: GenServer.on_start()
  def start_link(upstream_port),
    do: GenServer.start_link(__MODULE__, upstream_port)

  @doc "The port the proxy listens on."
  @spec port(proxy :: pid()) :: :inet.port_number()
  def port(proxy),
    do: GenServer.call(proxy, :port)

  @doc "Silently drops every flow the proxy currently carries."
  @spec drop(proxy :: pid()) :: :ok
  def drop(proxy),
    do: GenServer.call(proxy, :drop)

  @doc "How many dropped flows the client wrote to, and was answered with an RST."
  @spec resets(proxy :: pid()) :: non_neg_integer()
  def resets(proxy),
    do: GenServer.call(proxy, :resets)

  @impl GenServer
  def init(upstream_port) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

    {:ok, port} = :inet.port(listen)
    proxy = self()
    spawn_link(fn -> _accept(listen, upstream_port, proxy) end)

    {:ok, %{listen: listen, port: port, flows: [], resets: 0}}
  end

  @impl GenServer
  def handle_call(:port, _from, state),
    do: {:reply, state.port, state}

  def handle_call(:drop, _from, state) do
    Enum.each(state.flows, &send(&1, :drop))
    {:reply, :ok, %{state | flows: []}}
  end

  def handle_call(:resets, _from, state),
    do: {:reply, state.resets, state}

  @impl GenServer
  def handle_info({:flow, flow}, state),
    do: {:noreply, %{state | flows: [flow | state.flows]}}

  def handle_info(:reset, state),
    do: {:noreply, %{state | resets: state.resets + 1}}

  defp _accept(listen, upstream_port, proxy) do
    listen
    |> :gen_tcp.accept()
    |> case do
      {:ok, client} ->
        _open_flow(client, upstream_port, proxy)
        _accept(listen, upstream_port, proxy)

      {:error, :closed} ->
        exit(:shutdown)
    end
  end

  defp _open_flow(client, upstream_port, proxy) do
    {:ok, upstream} =
      :gen_tcp.connect(~c"127.0.0.1", upstream_port, [:binary, {:active, false}])

    flow = spawn(fn -> _await_sockets(proxy) end)
    :ok = :gen_tcp.controlling_process(client, flow)
    :ok = :gen_tcp.controlling_process(upstream, flow)
    send(flow, {:sockets, client, upstream})
    send(proxy, {:flow, flow})
  end

  defp _await_sockets(proxy) do
    receive do
      {:sockets, client, upstream} ->
        :ok = :inet.setopts(client, active: true)
        :ok = :inet.setopts(upstream, active: true)
        _carry(client, upstream, proxy)
    end
  end

  defp _carry(client, upstream, proxy) do
    receive do
      {:tcp, ^client, data} ->
        :ok = :gen_tcp.send(upstream, data)
        _carry(client, upstream, proxy)

      {:tcp, ^upstream, data} ->
        :ok = :gen_tcp.send(client, data)
        _carry(client, upstream, proxy)

      {:tcp_closed, _either} ->
        :gen_tcp.close(client)
        :gen_tcp.close(upstream)

      :drop ->
        :gen_tcp.close(upstream)
        _dropped(client, proxy)
    end
  end

  defp _dropped(client, proxy) do
    receive do
      {:tcp, ^client, _data} ->
        # Counted before the RST goes out, so the client never sees it ahead of the count.
        send(proxy, :reset)
        :ok = :inet.setopts(client, linger: {true, 0})
        :gen_tcp.close(client)

      {:tcp_closed, ^client} ->
        :ok

      {:tcp, _upstream, _late_data} ->
        _dropped(client, proxy)

      {:tcp_closed, _upstream} ->
        _dropped(client, proxy)
    end
  end
end
