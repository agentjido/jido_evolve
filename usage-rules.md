# Usage Rules

These rules define recommended usage for AI-assisted development with this package.

## Intended Use

- Use `Jido.Evolve.run/1` for final results and `evolve/1` for progress.
- Prefer explicit fitness modules with deterministic behavior for repeatable runs.
- Provide a random seed in config for reproducible test scenarios.
- Register callback-owned external work with `Jido.Evolve.Cleanup.register/1`.
  A worker's `after` block cannot clean resources after a forced stop. Follow
  the cleanup contract in `guides/getting-started.md` and use a finite cleanup budget.

## Safety and Reliability

- Treat fitness functions as untrusted runtime code; always handle `{:error, reason}` returns.
- Keep mutation and selection strategies side-effect free.
- Validate user input through public constructors and options parsers.

## Documentation Expectations

- Public modules/functions should include docs and examples.
- Internal plumbing may use `@moduledoc false` and `@doc false` when intentionally private.

## Release Rules

- Do not publish unless `mix quality`, `mix coveralls`, and `mix docs` all pass.
- Do not edit `CHANGELOG.md`; release notes are generated from Git history.
