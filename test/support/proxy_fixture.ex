defmodule GraphConn.Test.ProxyFixture do
  @moduledoc """
  The squid instance the proxy tests connect through, started by `docker-compose.test.yaml`.
  """

  # 3128 on the host is taken by the actionhandler test fixture.
  @port 3129
  @probe_timeout_in_ms 500

  @doc "Host port the squid container publishes."
  @spec port :: pos_integer()
  def port, do: @port

  @doc "Whether squid is listening, so the proxy tests can be run at all."
  @spec reachable? :: boolean()
  def reachable? do
    ~c"127.0.0.1"
    |> :gen_tcp.connect(@port, [:binary, {:active, false}], @probe_timeout_in_ms)
    |> case do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end
end
