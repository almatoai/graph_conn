# Used by "mix format"
[
  import_deps: [:plug],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    # Not fixtures/**: a fixture's deps/ and _build/ live under it.
    "fixtures/*/{mix,check}.exs",
    "fixtures/*/lib/**/*.ex"
  ]
]
