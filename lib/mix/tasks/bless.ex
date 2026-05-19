defmodule Mix.Tasks.Bless do
  @moduledoc """
  Runs checks that need to pass before pushing to the repo.

  It checks:
  - There are no compiler warnings
  - Code is formatted
  - Tests are passing and we have minimal coverage
    (threshold is specified in `./coveralls.json` file).
  - Static type analyses with dialyzer are passing.
  - Documentation is generated (without errors and warnings).

  This Mix task ships with the library and is therefore visible to apps that
  depend on it; it intentionally excludes opinionated checks (credo, sobelow,
  deps.audit). For graph_conn's own CI those run via the `bless` alias defined
  in `mix.exs`, which overrides this task within the project.
  """

  use Mix.Task

  @shortdoc "Runs all checks required to push project to repo"
  @doc false
  @spec run(args :: OptionParser.argv()) :: :ok
  def run(_) do
    [
      {"compile", ["--warnings-as-errors", "--force"]},
      {"format", ["--check-formatted"]},
      {"coveralls.html", []},
      {"dialyzer", []},
      {"docs", []}
    ]
    |> Enum.each(fn {task, args} ->
      [:cyan, "Running #{task} with args #{inspect(args)}"]
      |> IO.ANSI.format()
      |> IO.puts()

      Mix.Task.run(task, args)
    end)
  end
end
