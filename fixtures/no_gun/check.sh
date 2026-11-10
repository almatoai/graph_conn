#!/bin/sh
# Builds graph_conn consumers with and without its optional deps and checks what they get.
# Run from anywhere.
set -eu
cd "$(dirname "$0")"

# graph_conn builds test/support only in :dev and :test, so check a prod and a test build without
# gun, a test build with gun but without cachex, and a prod build with none of the optional deps.
# Pass build names to run only those.
builds="prod test test-with_gun prod-bare"
for build in ${@:-$builds}; do
  case " $builds " in
    *" $build "*) ;;
    *) echo "Unknown build: $build (known: $builds)" >&2; exit 1 ;;
  esac

  echo "== $build"
  export MIX_ENV="${build%%-*}"
  case "$build" in
    *-*) export VARIANT="${build#*-}" ;;
    *) unset VARIANT ;;
  esac

  # A path dep can keep a stale build, so every run starts from a clean one.
  rm -rf _build
  mix deps.get
  mix deps.compile

  # graph_conn is compiled as a dependency here, so --warnings-as-errors would not cover it:
  # recompile it on its own and fail on any warning it prints.
  log=$(mix deps.compile graph_conn --force 2>&1) || { echo "$log"; exit 1; }
  echo "$log"
  if echo "$log" | grep -q "warning:"; then
    echo "graph_conn compiled with warnings ($build)" >&2
    exit 1
  fi

  mix compile --warnings-as-errors
  mix run check.exs
done
