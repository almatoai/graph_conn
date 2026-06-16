defmodule GraphConn.MixProject do
  use Mix.Project

  @mix_env Mix.env()

  @spec project() :: keyword()
  def project do
    [
      app: :graph_conn,
      version: "1.9.12",
      elixir: "~> 1.17",
      start_permanent: true,
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_deps: :apps_direct,
        plt_add_apps: [:mix, :plug, :cowboy, :jason, :mint, :public_key, :credo, :ranch]
      ],
      name: "GraphConn",
      docs: _docs(),
      deps: _deps(),
      aliases: _aliases(),
      elixirc_paths: _elixirc_paths(Mix.env())
    ]
  end

  @spec application() :: keyword()
  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
    |> _start_server(@mix_env)
  end

  @spec cli() :: keyword()
  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        dialyzer: :test,
        docs: :test,
        bless: :test
      ]
    ]
  end

  # if you want to connect to local aapi comment this function
  # defp _start_server(list, :dev),
  #   do: [{:mod, {GraphConn.MockGraphApplication, []}} | list]

  defp _start_server(list, _), do: list

  defp _deps do
    [
      {:elixir_uuid, "~> 1.2"},
      # {:gun, "~> 2.1.0"},
      {:gun, github: "burmajam/gun", branch: "fix-proxy-problem"},
      {:finch, "~> 0.10"},
      {:ssl_verify_fun, "~> 1.1"},
      {:certifi, "~> 2.12"},
      {:jason, "~> 1.1"},
      ## needed for action handlers only
      {:cachex, "~> 4.0", optional: true},
      {:cowlib, "~> 2.9", override: true},
      {:telemetry, "~> 0.4 or ~> 1.0"},

      # test dependencies
      {:ring_logger, "~> 0.10", only: :dev},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.21", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.12", only: [:dev, :test], runtime: false},
      {:plug_cowboy, "~> 2.1"}
    ]
  end

  defp _docs do
    [
      output: "doc"
    ]
  end

  # Ignored advisories — upstream has no patched version yet. Re-evaluate when
  # cowlib publishes a fix.
  #   GHSA-g2wm-735q-3f56 — cowlib: cookie request header injection (no patch yet)
  @ignored_advisories "GHSA-g2wm-735q-3f56"

  # `bless` is an alias (not a Mix.Task module) so the opinionated checks below
  # don't leak to apps that depend on this library. `Mix.Tasks.Bless` keeps a
  # minimal universal pipeline for the same reason.
  defp _aliases do
    [
      bless: [
        "compile --warnings-as-errors --force",
        "format --check-formatted",
        "credo --strict",
        "sobelow --exit low",
        "deps.audit --ignore-advisory-ids #{@ignored_advisories}",
        "docs",
        "cmd mix coveralls.html",
        "dialyzer"
      ]
    ]
  end

  defp _elixirc_paths(env) when env in [:dev, :test], do: ["lib", "test/support"]
  defp _elixirc_paths(_), do: ["lib"]
end
