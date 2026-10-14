# AGENTS.md: test/

Inline tests (ppx_expect) for each mapping module, plus the conformance suite that runs the adapter
through `banking-provider`'s `Conformance.Make`.

- `fixture.ml` loads `fixtures/*.json`. Fixtures are bodies from the provider's sandbox or reference,
  with ids replaced by placeholders (see `fixtures/README.md`).
- `test/live/` is the live sandbox run. It is compiled by `dune build` but talks to a provider only when
  credentials and an explicit flag are set. Do not add it to the offline suite.
