defmodule NoGun.MixProject do
  @moduledoc "A consumer of graph_conn without gun, or in other VARIANTs of its optional deps."
  use Mix.Project

  @spec project() :: keyword()
  def project do
    [
      app: :no_gun,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: _deps()
    ]
  end

  # Compiled in this project's env, as some consumers do, so :dev and :test also build
  # graph_conn's test/support.
  defp _deps do
    optional =
      "VARIANT"
      |> System.get_env()
      |> _optional()

    [{:graph_conn, path: "../..", env: Mix.env()} | optional]
  end

  # By default the consumer has no gun, but has cachex, so GraphConn.ActionApi.Handler and its gun
  # check exist, and plug_cowboy, so GraphConn.Test.MockServer can serve a running REST client.
  # VARIANT=with_gun builds the consumer that has gun but neither of those, VARIANT=bare the one
  # that has none of the three.
  defp _optional("with_gun"), do: [{:gun, "~> 2.1"}]
  defp _optional("bare"), do: []
  defp _optional(nil), do: [{:cachex, "~> 4.0"}, {:plug_cowboy, "~> 2.1"}]
  defp _optional(unknown), do: Mix.raise("Unknown VARIANT: #{inspect(unknown)}")

  @spec application() :: keyword()
  def application,
    do: [extra_applications: [:logger]]
end
