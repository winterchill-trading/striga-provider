# AGENTS.md: striga-provider

## Purpose

striga-provider is the adapter that implements the organisation's banking-provider interfaces
(`Provider.S` and `Sandbox.S`) over the banking API client `../striga-client`. It is the only
place that knows both sides: the application uses the neutral interfaces, and the mapping from
each operation, webhook and ledger entry to the provider's endpoints is in `docs/mapping.md`.
Sandbox by default.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | The `striga-provider` library: the adapter, the store of links the provider cannot hold, and one mapping module per concern |
| `test/` | Inline tests for each mapping module, plus the conformance suite run against the adapter |
| `test/fixtures/` | Recorded or copied provider responses and webhook bodies (ids replaced by placeholders) |
| `test/live/` | A live sandbox run, only with credentials and an explicit flag |
| `docs/` | `mapping.md`: every operation, webhook and ledger entry, currencies, KYC tiers, SCA, cards and gaps |
| `.github/` | `ci.yml` |
| `README.md` | Why it is separate, modules, conformance, known gaps |

## Build, test, docs

Run from the repository root, inside the workspace (`..` is the workspace root):

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @striga-provider/all
opam exec --switch 5.2.0+ox -- dune build --root .. @striga-provider/runtest
```

For parallel work, set `DUNE_BUILD_DIR=_build-striga-provider-<task>` (resolved from the workspace
root, because of `--root ..`).

Standalone (outside the workspace): add the organisation opam repository
(`opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git`),
install the dependencies with `opam install --deps-only .`, then `dune build` and `dune test`.
`striga-client` must be installable from the same repository or from a checkout beside this one.

## Conventions

- Format only this repository: `dune build --root .. @striga-provider/fmt --auto-promote`. Never run
  `dune fmt` at the workspace root.
- Every module has an `.mli`. Use labelled arguments, `open! Core` and `ppx_jane`.
- Provider names stay out of the application-facing interfaces. Only this repository and its client
  may name the provider.
- Each mapping module gets an expect test for its conversions, and the conformance suite must keep passing.
- Units: money is `Money` with exact amounts; provider tickers and smallest units are converted only in
  `units.ml`, and the conversions are tested there.
- Any change to `docs/mapping.md` happens in the same commit as the code it describes.
- Promote expect output with `dune promote` only after reading the diff.

## Dependencies and dependents

The library depends on `banking-provider` (the interfaces it implements), `striga-client` (the API
client), `kyc-core`, `payments-core`, `card-core`, `money` and `ledger`, and CI pins all of them from
GitHub in that order: fixed-decimal, money, ledger, kyc-core, payments-core, card-core, banking-provider,
striga-client.

## CI

`.github/workflows/ci.yml` runs the `ox-setup` composite action from `winterchill-trading/infra` with
the eight pins above, then `dune build` and `dune test`, plus the `obj-magic` reusable workflow. The
live run is not part of CI.
To check a run, use `gh run list --limit 1`, and at most one `gh run watch <id> --exit-status`.
Do not poll in a loop.

## Pitfalls

- The provider takes no idempotency keys. Idempotent creates live in the adapter's `Store`, which only
  an in-memory implementation ships here; a lost create response is recovered by a lookup by e-mail
  (unique per user at the provider) before creating again.
- The sandbox provisions accounts in stages, and some currencies may never appear for a given sandbox
  application. Do not shorten a scenario's wait in the adapter; let the suite's timeout decide, and record
  the gap in `README.md` if it persists.
- `banking-provider` moved its sandbox interface to `Sandbox.S`. An adapter's `.mli` needs
  `include Sandbox.S with type t := t`, and the `Conformance.Make` functor takes the adapter twice.
- A simulated deposit returns no transaction id. Tag it with a unique reference and find it on the
  statement by its memo.
- Fixtures: replace ids with placeholders and scrub sender names and personal data. Addresses and IBANs
  in fixtures are public test values chosen so that the payments-core checksum accepts them; keep them so.
- Provider-side decline reasons are on the statement, not on the authorisation response.

## Where to read more

- `README.md` (why separate, modules, conformance, known gaps) and `docs/mapping.md` (the full mapping).
- `../striga-client/README.md` for the client this adapter calls.
- `../banking-provider` (the interfaces) and `../specs/repos/striga-provider.md` for the repository summary.
- `../oxcaml-claude-skills/AGENTS.md` (workspace guide) and the skill
  `../oxcaml-claude-skills/skills/banking-standards/` for the banking rules the mappings follow.
- `../oxcaml-claude-skills/GOTCHAS.md`, section "Fiat rails: striga-client" (includes the adapter entries).

## Never do

- Install an opam package that changes the compiler, `core`, `base`, `async` or `ppx_jane` on the
  shared `5.2.0+ox` switch. Dry-run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Commit `.env`, a key, a secret, a token or an unsanitised response. `.env.example` is the template.
- Point a test or a script at a live provider host.
- Change the provider's application-wide settings from code. Those are changed by a person in the provider's dashboard.
- Publish, tag or release.
