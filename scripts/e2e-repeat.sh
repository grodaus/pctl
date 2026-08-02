#!/usr/bin/env bash
# Run the real-systemd e2e suite N times and report the pass rate.
#
# `dune build @e2e` green once is not evidence the gate is stable: the
# suite drives one shared `systemd --user` session, so a flake shows up
# as an occasional run, not an occasional test. pctl-jbd was a 1-in-3
# failure that a single run never caught. Use this before claiming the
# gate is green.
#
# Do NOT run a NixOS / home-manager activation while this is going. It
# reexecs the user manager, which fails whichever bus call pctl has in
# flight — that is what pctl-jbd turned out to be. Such a run is
# invalid, not a defect report. To tell the two apart:
#   journalctl --user --grep 'Reexecution requested'
# names the caller by comm: 'switch-to-confi' is an activation,
# 'systemctl' is test_reload_survives_reexec's own deliberate kicker.
#
# Usage: scripts/e2e-repeat.sh [runs]   (default 5)
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

runs=${1:-5}
# A gate-confidence script that silently ran zero times and exited 0
# would be worse than no script: `seq 1 0` is empty, so an unvalidated
# count reports green having built nothing.
if [[ ! $runs =~ ^[1-9][0-9]*$ ]]; then
  printf 'runs must be a positive integer, got: %s\n' "$runs" >&2
  exit 2
fi

pass=0
declare -a failed_runs=()
declare -a skipped_runs=()

# A skipped run exits 0 having executed nothing: Harness.skip_or_run
# prints `SKIP: <test> — <why>` and exits 0 when the host has no
# DBUS_SESSION_BUS_ADDRESS or no /run/user/<uid>. Treating that as a
# pass is the same failure mode the `runs` check above guards against,
# one layer down — green from a suite that never ran. So the output is
# captured and inspected, rather than trusting the exit status alone.
out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT

for i in $(seq 1 "$runs"); do
  printf '=== e2e run %d/%d ===\n' "$i" "$runs"
  dune build @e2e --force 2>&1 | tee "$out"
  # Both halves. A tee that failed leaves $out short or empty, which
  # reads as "no SKIP lines" — i.e. exactly the false green the capture
  # was added to close.
  # Copied in one go: a bare assignment is itself a command and resets
  # PIPESTATUS, so reading [1] on the next line would read its own.
  status=("${PIPESTATUS[@]}")
  rc=${status[0]}
  if ((status[1] != 0)); then
    printf 'tee failed (exit %d): cannot judge run %d\n' "${status[1]}" "$i" >&2
    exit 2
  fi
  skips=$(grep -c '^SKIP: ' "$out")
  if ((rc != 0)); then
    failed_runs+=("$i")
  elif ((skips > 0)); then
    skipped_runs+=("$i")
  else
    pass=$((pass + 1))
  fi
done

printf '\ne2e: %d/%d runs passed\n' "$pass" "$runs"
if ((${#skipped_runs[@]} > 0)); then
  printf 'SKIPPED runs (suite did not execute, not evidence of green): %s\n' \
    "${skipped_runs[*]}" >&2
fi
if ((${#failed_runs[@]} > 0)); then
  printf 'failed runs: %s\n' "${failed_runs[*]}" >&2
  exit 1
fi
# Distinct from 1: nothing failed, but nothing ran either.
((${#skipped_runs[@]} > 0)) && exit 2
exit 0
