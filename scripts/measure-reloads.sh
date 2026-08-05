#!/usr/bin/env bash
# Measure Manager.Reload cost per pctl command on a live user session.
#
# Reports, per command, the wall clock and the number of "Reload requested"
# entries the user manager logged for that command's own PID — the journal
# line names the requesting client, so a concurrent reload from another
# process is not counted. A journal cursor taken before the command excludes
# everything logged earlier.
#
# Reason it exists: pctl-e0d's arithmetic (reloads per command) is a claim
# about production code paths, and the only artifact that can contradict it
# is the manager's own log.
set -euo pipefail

PCTL=${PCTL:-_build/default/bin/pctl.exe}
[[ -x $PCTL ]] || { echo "no pctl at $PCTL — dune build bin/pctl.exe" >&2; exit 2; }

tmp=$(mktemp -d "/run/user/$(id -u)/pctl-measure-XXXXXX")
mkdir -p "$tmp/project" "$tmp/state"
export XDG_STATE_HOME="$tmp/state"

# Only XDG_STATE_HOME is redirected; the unit files land in the developer's
# live session under XDG_RUNTIME_DIR/systemd/user.control (lib/unit_store/fs.ml).
# Aborting between the runs below would otherwise leave the slice running with
# the registry that knew about it deleted, so take the project down first.
cleanup() {
  local rc=0 err
  # stderr is held back rather than passed through: on the two no-op paths below
  # it is a registry-I/O line about a project that was never registered, which
  # reads as a fault when nothing is wrong. It is printed only if we alarm.
  err=$("$PCTL" down --path "$tmp/project" 2>&1 >/dev/null) || rc=$?
  # Exit 4 from `down` is Registry_io (schema.ml:510 — Install_failed shares the
  # code, but down installs nothing): the registry does not know this project,
  # so nothing was ever installed under it. That is the state before the first
  # up and again after the measured down. Not a leak, so not an alarm.
  #
  # Any other failure IS the leak: the units stay installed in the live session
  # while the state dir holding the registry row that names them is about to be
  # deleted, which is precisely the orphan the gc classes exist to avoid.
  # (Registry_io also covers 'manifest row but no host', where units could
  # exist — that inconsistency is not reachable from this script.)
  if (( rc != 0 && rc != 4 )); then
    echo "measure-reloads: 'pctl down --path $tmp/project' exited $rc — units" \
         "may still be installed in $XDG_RUNTIME_DIR/systemd/user.control;" \
         "check 'systemctl --user list-units pctl-*' before the registry goes." \
         "down said: $err" >&2
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

cat >"$tmp/spec.json" <<'EOF'
{"services":{"web":{"kind":"simple","command":["/run/current-system/sw/bin/sleep","infinity"],
"service_config":{"Type":"simple"},"depends_on":[],
"workspace":{"cwd":false,"writable":false},"probe":null}},
"slice":{"slice_config":{}},"version":2}
EOF

# Standalone daemon-reload cost, for scale: everything below is a multiple of
# it. Sets REPLY_MS rather than echoing, so the reload runs in this shell and
# set -e aborts on a failed one instead of it becoming a small ms figure.
reload_ms() {
  local t0 t1
  t0=$(date +%s%N)
  systemctl --user daemon-reload
  t1=$(date +%s%N)
  REPLY_MS=$(( (t1 - t0) / 1000000 ))
}
# Assigned, then echoed. Inside `echo` the substitution's failure would be
# discarded — `echo "$(false | wc -l)"` prints 0 and continues, and not even
# `shopt -s inherit_errexit` changes that. In an assignment the status is the
# assignment's own, so errexit fires. Same reason every other $() here is one.
unit_files=$(systemctl --user list-unit-files --no-legend | wc -l)
echo "unit files in search path: $unit_files"
baseline=""
for _ in 1 2 3; do reload_ms; baseline+=" ${REPLY_MS}ms"; done
echo "bare daemon-reload:$baseline"

run() {
  local label=$1; shift
  local cursor pid t0 t1 journal reloads
  cursor=$(journalctl --user -n0 --show-cursor -q | sed -n 's/^-- cursor: //p')
  # A count is the whole output of this script, so a journal it could not read
  # must not print as reloads=0 — which would read as confirmation of exactly
  # the arithmetic this script exists to be able to contradict.
  [[ -n $cursor ]] || { echo "no journal cursor — cannot count reloads" >&2; exit 3; }
  t0=$(date +%s%N)
  # Backgrounded only to learn the PID: the manager logs "Reload requested from
  # client PID <n>", and <n> is the pctl process, so the count is this
  # command's and not any concurrent reload's.
  "$PCTL" "$@" >/dev/null &
  pid=$!
  wait "$pid"
  t1=$(date +%s%N)
  journal=$(journalctl --user --after-cursor "$cursor" -q)   # set -e catches a failed read
  reloads=$(grep -c "Reload requested from client PID $pid " <<<"$journal" || true)
  printf '%-22s %5dms  reloads=%s\n' "$label" $(( (t1 - t0) / 1000000 )) "$reloads"
}

# Every mutating command. `gc --yes` is absent: it only reloads when it
# actually removed something, which needs a non-Live row, and this script's
# project is the Live one it just created.
run "up (fresh)"      up      --path "$tmp/project" --tree "$tmp/spec.json"
run "up (idempotent)" up      --path "$tmp/project" --tree "$tmp/spec.json"
run "reload"          reload  --path "$tmp/project" --tree "$tmp/spec.json"
run "restart"         restart --path "$tmp/project"
run "down"            down    --path "$tmp/project"
