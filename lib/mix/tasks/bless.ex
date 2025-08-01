defmodule Mix.Tasks.Bless do
  @moduledoc """
  Runs checks that need to pass before pushing to the repo.

  It checks:
  - There are no compiler warnings
  - Code is formatted
  - Tests are passing and we have minimal coverage
    (threshold is specified in `./coveralls.json` file.
  - Static type analyses with dialyzer are passing.
  - Documentation is generated (without errors and warnings).
  """

  use Mix.Task

  @shortdoc "Runs all checks required to push project to repo"
  @doc false
  def run(_) do
    [
      {"compile", ["--warnings-as-errors", "--force"]},
      {"format", ["--check-formatted"]},
      {"deps.audit", []},
      {"sobelow", ["--config", "--skip", "--exit", "Low"]},
      {"coveralls.html", []},
      # {"credo", []},
      {"dialyzer", []},
      {"docs", []}
    ]
    |> Enum.each(fn {task, args} ->
      IO.ANSI.format([:cyan, "Running #{task} with args #{inspect(args)}"])
      |> IO.puts()

      Mix.Task.run(task, args)
    end)
  end
end
