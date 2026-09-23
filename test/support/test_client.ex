defmodule GraphConn.TestClient do
  @moduledoc "Starting, stopping and timing the TestConn client from a test."

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias GraphConn.TestConn

  @doc """
  Starts a supervisor for TestConn, forwarding its status changes to the calling process.

  `config_overrides` are merged over the client's configured options.
  """
  @spec start(config_overrides :: Keyword.t()) :: Supervisor.on_start()
  def start(config_overrides \\ []) do
    :graph_conn
    |> Application.get_env(TestConn)
    |> Keyword.merge(config_overrides)
    |> TestConn.start_supervisor(%{forward_to: self()})
  end

  @doc """
  Leaves no client running for TestConn.

  Waits for its table to go with it, so the next test doesn't race the teardown.
  """
  @spec stop() :: :ok
  def stop do
    TestConn
    |> Module.concat(Supervisor)
    |> Process.whereis()
    |> case do
      nil -> :ok
      pid -> Process.exit(pid, :test_cleanup)
    end

    deadline = System.monotonic_time(:millisecond) + 2_000
    _wait_for_client_gone(deadline)
  end

  @doc "Runs `fun`, returning how long it took in milliseconds alongside its result."
  @spec measure(fun :: (-> result)) :: {elapsed_in_ms :: non_neg_integer(), result}
        when result: term()
  def measure(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  @doc """
  Puts `value` under `key` in the `:graph_conn` env for the duration of the calling test.

  The previous value, or its absence, is restored on exit.
  """
  @spec put_env(key :: atom(), value :: term()) :: :ok
  def put_env(key, value) do
    original = Application.fetch_env(:graph_conn, key)
    Application.put_env(:graph_conn, key, value)

    on_exit(fn ->
      case original do
        {:ok, previous} -> Application.put_env(:graph_conn, key, previous)
        :error -> Application.delete_env(:graph_conn, key)
      end
    end)
  end

  # Both, not just the table: the table dies with `ConnectionManager`, which the supervisor
  # terminates BEFORE unregistering its own name -- so waiting on the table alone returns while
  # the name is still taken, and the next `start/1` gets `{:error, {:already_started, pid}}`.
  defp _wait_for_client_gone(deadline) do
    supervisor =
      TestConn
      |> Module.concat(Supervisor)
      |> Process.whereis()

    cond do
      is_nil(supervisor) and :ets.whereis(TestConn) == :undefined ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        _wait_for_client_gone(deadline)

      true ->
        raise "TestConn outlived its supervisor: #{inspect(supervisor)}"
    end
  end
end
