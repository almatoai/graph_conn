defmodule GraphConn.MixProject do
  use Mix.Project

  # Advisories waived for `hex.audit` (Hex/OSV ids). `@ignored_advisories` below is the
  # separate list `deps.audit` reads; an id in the wrong list is silently ignored.
  #
  # cowlib 2.20.0 is its latest release; neither flaw has a patched version.
  #   EEF-CVE-2026-43966 — cow_http_struct_hd:escape_string/2 serialises outgoing headers; gun
  #   never calls it and cowboy here serves only the test mock server
  #   EEF-CVE-2026-43969 — cow_cookie:cookie/1 is reached only via gun's cookie_store, never set
  #
  # mint is locked at 1.10.1: 1.11.0 pools a connection after a receive timeout and the next
  # request on it crashes on the stale reply. mint's only user is the HTTP/1 Finch pool.
  #   EEF-CVE-2026-91043 — HTTP/2 only
  #   EEF-CVE-2026-92103 — HTTP/2 only
  #   EEF-CVE-2026-94194 — HTTP/1 chunked response smuggling: in reach, risk accepted (needs a
  #   hostile graph or intermediary, including the configured proxy)
  #
  # GHSA-w4f7-4cxr-rv3c — self-inconsistent for gun, see `@ignored_advisories` below
  @ignored_hex_advisories [
    "EEF-CVE-2026-43966",
    "EEF-CVE-2026-43969",
    "EEF-CVE-2026-91043",
    "EEF-CVE-2026-92103",
    "EEF-CVE-2026-94194",
    "GHSA-w4f7-4cxr-rv3c"
  ]

  @spec project() :: keyword()
  def project do
    [
      app: :graph_conn,
      version: "1.11.0",
      elixir: "~> 1.17",
      start_permanent: true,
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_deps: :apps_direct,
        # :ex_unit because dialyzer analyses test/support, which is compiled in :dev and :test.
        plt_add_apps: [
          :mix,
          :plug,
          :cowboy,
          :jason,
          :mint,
          :public_key,
          :credo,
          :ranch,
          :ex_unit
        ]
      ],
      name: "GraphConn",
      docs: _docs(),
      deps: _deps(),
      aliases: _aliases(),
      hex: [ignore_advisories: @ignored_hex_advisories],
      elixirc_paths: _elixirc_paths(Mix.env())
    ]
  end

  @spec application() :: keyword()
  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
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

  defp _deps do
    [
      {:elixir_uuid, "~> 1.2"},
      {:gun, "~> 2.1"},
      {:finch, "~> 0.10"},
      {:ssl_verify_fun, "~> 1.1"},
      {:certifi, "~> 2.12"},
      {:jason, "~> 1.1"},
      ## needed for action handlers only
      {:cachex, "~> 4.0", optional: true},
      ## needed for GraphConn.Test.MockServer only
      {:plug_cowboy, "~> 2.1", optional: true},
      {:telemetry, "~> 0.4 or ~> 1.0"},

      # test dependencies
      {:ring_logger, "~> 0.10", only: :dev},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.21", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.12", only: [:dev, :test], runtime: false}
    ]
  end

  defp _docs do
    [
      output: "doc"
    ]
  end

  # Ignored advisories.
  #   GHSA-w4f7-4cxr-rv3c — self-inconsistent for gun: affected `< 2.4.0`, yet "patched" in
  #   2.16.0, which is cowboy's fix and no gun version, so OSV and mix_audit flag gun 2.6.0.
  #   The real flaw is in cowlib, waived as EEF-CVE-2026-43966 in `@ignored_hex_advisories`.
  @ignored_advisories "GHSA-w4f7-4cxr-rv3c"

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
        "cmd mix hex.audit",
        "docs",
        "cmd mix coveralls.html --exclude feature",
        "cmd mix test --only feature",
        "dialyzer"
      ]
    ]
  end

  defp _elixirc_paths(env) when env in [:dev, :test], do: ["lib", "test/support"]
  defp _elixirc_paths(_), do: ["lib"]
end
