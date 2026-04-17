# Call by Hash

**Source:** https://garnix.io/blog/call-by-hash/ — Julian K. Arni, 2024-03-14

## Thesis

Immutable, content-hashed URLs for services simplify deployment and make infrastructure-wide atomic upgrades tractable.

## Deployment Goals

1. No dropped requests (no missing-server window).
2. Every in-flight request completes (no mid-request termination).
3. Deploy time ≤ slowest service startup.
4. Atomic upgrades across all services (no old/new mixing).
5. No extra complexity (service meshes, control planes).

## Existing Strategies Fall Short

| Strategy | Wins | Loses |
|---|---|---|
| Pit-stop | simple, fast | downtime; no atomic upgrade |
| Rolling | no dropped requests, redundant | slow; versions coexist → hard to make breaking changes |
| Blue-green | atomic switch | can't guarantee request completion across services; needs mesh/DNS hacks for version-pinned routing; redeploys unchanged services |

## Nix Insight

Nix moves name resolution from runtime to build time. Paths like `/nix/store/<hash>-bash/bin/sh` are immutable — same hash, same bytes, forever. Whole builds become reproducible and hashable.

## Call by Hash

Apply the same trick to service URLs. Each service gets a DNS name derived from its build hash:

```nix
nixosConfigurations = rec {
  backend = ...;
  frontend = ... ''
    runFrontend --backendUrl ${mkHashUrl backend};
  '';
}
```

Yields `14sk2w...garnix.me` → backend, `09lb3m...garnix.me` → frontend. Frontend only talks to that exact backend hash. Change backend → its hash changes → frontend's hash changes (transitively) → frontend redeploys. Unrelated services untouched.

## Payoff

- **Known consumers.** Hash dependency graph reveals who calls what → safe breaking changes.
- **Atomic upgrades.** Hash propagation is the atomic switch.
- **Audit trail.** Any change (incl. deps) alters the name, visible in logs.
- **Request completion.** Shutdown order follows the dep graph.
- **Smaller deploys.** Only affected services redeploy; unchanged services shared across environments (incl. PR previews).
- **No mesh/overlay.** DNS + hashes do the work.

## Open Ground

- Socket activation + scale-to-zero → every version of every service persists → fearless breaking changes in public APIs.
- Persistence (DBs, migrations) not covered — follow-up posts.
- Webhooks / circular deps not covered.
