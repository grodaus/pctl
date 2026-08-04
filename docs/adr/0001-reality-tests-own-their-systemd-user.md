# Reality tests run against a nested `systemd --user`, not the session's

## Status

proposed

## Decision

Each **reality test** spawns its own `systemd --user` as a child process, with
private runtime, config and data directories and a unit search path restricted
to the test's **user.control** plus the minimum set a user manager needs in order
to boot and own a bus. Tests do not use the manager of whoever runs them.

## Why

Sharing one manager with the developer's login session made four properties
unreachable rather than merely awkward, and all four follow from the sharing
rather than from any individual test: the suite could not run in parallel; state
accumulated in that manager across runs; reload cost scaled with whatever the
developer happened to have installed; and the reexec tests had to disturb the
session the developer's desktop depends on.

A nested manager starts in well under a second, reloads an order of magnitude
faster than a desktop session, and delegates cgroups well enough to run real
services. The measurements behind those claims live on the epic that implements
this decision.

## Considered options

**Keep using the session manager.** Highest fidelity — it is what pctl's users
actually run against. Rejected because none of the four problems is fixable while
the manager is shared, and because reexec'ing a developer's desktop is not a
reasonable price for a test suite.

**A dedicated lingering test user.** Isolates the developer, but still shares one
manager across all tests, so serialisation and accumulation remain. Also needs
root to provision.

**Always use a VM.** Hermetic and isolated, but boot cost is two orders of
magnitude above a nested manager, so it cannot be the inner loop. See ADR 0002 —
the VM earns its place for a different reason.

## Consequences

Fidelity is the cost. A nested manager is not a login session, so a defect that
only manifests under a real `user@.service` — different inherited environment,
`logind` interaction, a different generator set — escapes this layer. Accepted
because the gap is narrow and ADR 0002 covers the hermetic case, but it is the
reason to reach for the session manager deliberately when debugging an
interaction with it.

Two failure modes are silent, and both produce a green suite that tested less
than it appears to:

- `SYSTEMD_UNIT_PATH` in its trailing-colon form appends the default search path,
  restoring both the full unit set and the coupling between tests.
- A manager that does not die with its parent is reparented to PID 1, units still
  running, whenever a test is killed rather than returning. Teardown cannot cover
  this, since it does not run on `SIGKILL`. The child needs `PR_SET_PDEATHSIG` or
  a process group the harness kills as a group.
- Curating the search path removes capabilities as well as cost, and the manager's
  own shutdown path is a unit like any other. An under-curated set does not fail
  loudly; it produces a manager that cannot be asked to stop, which is the leak
  the previous point guards against arriving by a second route.
