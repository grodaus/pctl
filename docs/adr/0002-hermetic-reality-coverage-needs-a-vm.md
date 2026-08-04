# Hermetic reality coverage requires a NixOS VM, so there are two test backends

## Status

proposed

## Decision

A NixOS VM check runs the **reality test** executables inside a guest and enters
`checks`. It coexists with the nested manager of ADR 0001 rather than replacing
it: nested is the dev loop, the VM is the hermetic gate.

## Why

`systemd --user` calls `sd_booted()` and refuses to start where
`/run/systemd/system` is absent. The Nix build sandbox has no systemd, so no
configuration puts a user manager inside `nix flake check`. This is a hard
precondition, not a permissions or cgroup problem, and a VM is the only way the
reality layer reaches the command that runs every other check.

Two properties of that layer make the reach worth paying for. Coverage that
exists only on a developer's host is coverage CI cannot enforce. And the
reexec-window tests are statistical by construction — the fault must land inside
an in-flight call — so their value comes from running often and everywhere, which
is exactly what a host-only suite denies them.

## Considered options

**Nested manager only.** Cheapest, and it covers the dev loop well. Rejected
because it leaves the reality layer permanently outside `nix flake check`.

**VM only.** One backend, so no divergence risk. Rejected on cost: boot is two
orders of magnitude above a nested manager, which is not an inner loop.

**microvm.nix with VM snapshots.** Attacks boot cost directly. Rejected because
the isolation boundary that matters turned out to be the user manager rather than
the machine — restarting it is cheap enough that one boot serves many isolated
tests, leaving snapshots little to optimise. Snapshot restore would also step
`CLOCK_MONOTONIC`, which `Bus_retry` depends on to keep a `CLOCK_REALTIME` step
from ending its budget early. Revisit if parallel VM boots ever become the
bottleneck.

## Consequences

Two backends over one body of test code diverge only environmentally, and that
divergence is the point rather than a liability. pctl's entire subject is
behaviour against systemd, so environment-dependent defects are its native bug
class, and one environment cannot expose them by construction.

The sharpest instance is version. A guest's systemd is a locked flake input, so
drift arrives as a reviewable lockfile change and a failing check on the commit
that causes it. On a developer's host it arrives silently — this project has
already spent tickets reconciling recorded systemd measurements against a host
that had moved underneath them.

The cost is that a one-sided failure has to be diagnosed rather than retried. A
red VM against a green dev loop is a finding, and treating it as flakiness throws
away exactly the signal the second backend exists to produce. That is only
tractable if the environmental delta stays small enough to enumerate.

Neither backend is a desktop login session — one is a nested manager with a
curated unit search path, the other a lingering headless user — and that is what
every real user runs. The delta is smaller than it sounds, and it is enumerable,
which is what makes the previous paragraph's diagnosis tractable:

A pctl unit cannot reference an external unit. `service_config` renders into
`[Service]`, and the only `[Unit]` dependencies are those derived from
`depends_on`, which resolve to sibling pctl services. So the large difference
between the two environments — how many unit files exist to be depended on —
cannot reach a rendered unit, and costs no fidelity.

What remains is what a service inherits rather than what it can name: a desktop
session's manager carries `XDG_SEAT`, `XDG_SESSION_ID`, `XDG_SESSION_TYPE`,
`XDG_SESSION_CLASS`, `XDG_SESSION_DESKTOP` and `XDG_VTNR`, and a nested manager
does not. A service reading any of those behaves differently. The harness keeps an
opt-in path back to the session manager for that case, unused by default.

Guest boot must be trimmed to be tolerable — the default waits on network
configuration these tests never use.

This does not simplify CI. When the decision was taken, the project's hardened
runner denied both KVM and writable cgroups, so it could host neither backend and
both jobs had to stay on the privileged runner; moving the fast job would mean
relaxing hardening on the runner that executes pull-request code. The specifics
are recorded on the epic that implements this.
