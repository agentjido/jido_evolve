**Cleanup update — 13 September 2026**

Issue [#33](https://github.com/agentjido/jido_evolve/issues/33) is addressed by
`Jido.Evolve.Cleanup.register/1`. Each evaluation and GEPA reflection has a
separate callback owner. It retains registered cleanup functions when a worker
times out, is cancelled, crashes, or loses its caller. Evaluation and run deadlines
remain active when the search caller is suspended.

Cleanup functions run concurrently after the callback stops. They share one
positive, finite `cleanup_timeout` budget. Errors and cleanup timeouts are retained
in the evaluation or reflection failure. Failed cleanup after cancellation does
not mark an interrupted population complete. See the
[cleanup contract](../guides/getting-started.md#detached-work-and-cleanup) for
registration before resource startup and the limits of external cancellation.

The local API and GEPA work below is included with this fix. The new records use
plain structs and type specifications; no TypedStruct dependency is added.
The migration guide records the breaking API changes. The version remains 1.0.0;
version selection and publishing remain separate release work.

Validation on 13 September 2026:

- `mix test --cover --warnings-as-errors`: 323 passing checks; 92.1% coverage.
- `mix quality` and `mix docs -f html`: passed.
- The API walkthrough and offline GEPA example: passed.
- HTN integration: 40 passing tests. Existing HTN example warnings about
  `Jido.Agent.Directive.spawn_agent/3` remain outside this change.

**Core implementation — 4 September 2026**

The accepted package scope is implemented in the working tree.

- One generational GA supports custom data and operators, explicit operator options, scalar minimization/maximization, and optional diversity.
- Each member has a separate evaluation record. Metadata and feedback survive evaluation. Invalid results and failures have no score.
- `evolve/1` is lazy and includes the terminal state. `run/1` returns the best evaluation seen, the last complete population, counts, and stop reason.
- Evaluation limits, deadlines, cancellation, task cleanup, and run-owned random state are implemented. Synchronous variation callbacks must return promptly.
- Binary, string, permutation, and parameter map examples use the public API. Parameter schemas are validated before evaluation.
- HTN uses fixed external evaluation cases during search and final acceptance. Local integration uses `JIDO_EVOLVE_PATH=../jido_evolve`.

Validation:

- `mix test --cover`: 292 passing checks; 93.3% coverage.
- `mix quality`: passed, including compilation, Dialyzer, and documentation checks.
- `mix docs -f html`: passed.
- HTN `mix quality` with the local dependency: passed.
- HTN integration: 40 passing tests across the evolver, fitness adapter, and domain mutation modules.

Breaking changes are recorded in [the migration guide](../guides/migration.md).
The manifest remains at 1.0.0. Version selection, publishing, and the optional
Python GEPA comparison are not part of this implementation.

Follow-up examples:

- `examples/gepa/offline.exs` runs the core GEPA steps in an example search loop.
  It uses the public evaluator path with fixed training and validation cases,
  a candidate archive, component reflection, and separate call limits.
- `examples/gepa/live.exs` connects task and reflection models through optional
  ReqLLM 1.21.1. Its dependency and message-format check passed. No paid model
  request was made.
- The offline fixture improved validation and test results from 0/6 to 6/6.
  It used 87 search case evaluations, 12 mock reflections, and 12 final test evaluations.
- `mix test --warnings-as-errors`: 303 passing checks, including 11 new example tests.
  The docs build passed. The earlier coverage figure above is from the core scope validation.

See [the example guide](../guides/gepa-examples.md). This is not a supported native
GEPA API or a comparison with Python GEPA. The public package scope is unchanged.
