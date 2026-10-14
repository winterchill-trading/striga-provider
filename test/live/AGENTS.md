# AGENTS.md: test/live/

A live run against the provider's sandbox (`live.ml`). It runs only with credentials loaded from the
environment and an explicit flag, and it creates sandbox users and accounts.

- Run it by hand. Do not run it from CI, from a loop, or from a script that also writes fixtures.
- Each scenario reports one line; a provider-side wait that never ends is recorded as a gap, not hidden.
