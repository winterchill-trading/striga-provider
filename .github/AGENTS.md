# AGENTS.md: .github/

`workflows/ci.yml`: the `ox-setup` composite action with eight sibling pins (keep them in dependency
order and in step with `striga-provider.opam`), then `dune build` and `dune test`, plus the
`obj-magic` reusable workflow.

- When a dependency is added or removed, update the pins in the same commit.
- Check runs with `gh run list --limit 1`; at most one `gh run watch <id> --exit-status`. No loops.
