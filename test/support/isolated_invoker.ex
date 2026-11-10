# Needs gun for its WebSocket and plug_cowboy for GraphConn.Test.MockServer, so it is left out of a
# consumer build without either.
if Code.ensure_loaded?(:gun) and Code.ensure_loaded?(Plug.Cowboy) do
  defmodule GraphConn.Test.IsolatedInvoker do
    @moduledoc "An action invoker on its own mock identity, for tests that arm faults against it."

    use GraphConn.ActionApi.Invoker

    alias GraphConn.Test.MockServer

    @doc "Reconfigures, and tells a process registered as `#{inspect(__MODULE__)}.Observer` how it went."
    @spec on_config_changed() :: any()
    def on_config_changed do
      result = reconfigure()

      __MODULE__
      |> Module.concat(Observer)
      |> Process.whereis()
      |> case do
        nil -> result
        observer -> send(observer, {:reconfigured, result})
      end
    end

    @doc "The invoker's config: the shared test conn's, on the isolated identity, with `opts` on top."
    @spec config(opts :: Keyword.t()) :: Keyword.t()
    def config(opts \\ []) do
      config = Application.get_env(:graph_conn, GraphConn.TestConn)
      credentials = MockServer.valid_isolated_invoker_credentials()

      auth =
        config
        |> Keyword.fetch!(:auth)
        |> Keyword.put(:credentials, credentials)

      config
      |> Keyword.put(:auth, auth)
      |> Keyword.merge(opts)
    end
  end
end
