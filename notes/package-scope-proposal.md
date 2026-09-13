**Jido.Evolve package scope**

Accepted scope, 4 September 2026. Implemented in the working tree; release is pending.
See [implementation checks](implementation-status.md) and [migration notes](../guides/migration.md).

> Jido.Evolve provides evolutionary search over Elixir data. Applications supply candidates, evaluation, and variation rules. The package controls the search, evaluation budget, concurrent work, and results.

The package serves Elixir developers who need to improve configurations, orderings, policies, or other structured values against a measurable objective. It must work without Jido agents, a language model, Python, or a numerical backend.

The next release delivers **one reliable, extensible genetic algorithm**. Flexibility means that applications can supply their own data and operators.

**Required for the next release**

| Area | Commitment |
| --- | --- |
| Search | One generational GA with tournament parent selection by default, configurable mutation and crossover, and explicit elitism. |
| Representation | Support strings, binary lists, permutations, and bounded parameter maps. Accept custom data through application callbacks. Make diversity measurement optional. |
| Operators | Retain fitness, mutation, selection, and crossover extension points. Pass explicit strategy options, including schemas. Validate required options before starting work. |
| Evaluation | Support scalar minimize/maximize objectives. Separate invalid candidates and failed evaluations from valid scores. Preserve metadata and optional feedback; support one tested feedback-driven mutation path. |
| Execution | Bound evaluation concurrency and timeout. Support evaluation and generation limits, a deadline, cancellation, and a random state owned by each run. |
| Results | Provide progress through `evolve/1` and a final result through `run/1`, using the same engine. Report the best valid candidate seen, its evaluation, the last complete population, work counts, and stop reason. |

**Required behavior**

- Generation 0 is the evaluated initial population. `generations: N` permits at most N breeding transitions. The stream returns every completed generation, including the state that meets a stop condition.
- Stream construction starts no evaluation. Consumption computes only the requested generation.
- Each attempted candidate evaluation consumes one budget unit, including failed attempts. Reject a budget too small for the initial population. Stop before a generation that would exceed the remaining evaluation budget.
- A deadline or cancellation stops new scheduling and terminates evaluation tasks owned by the run. Report the best completed valid evaluation and the last complete population, if available.
- Preserve the configured population size. Equal candidate values remain distinct members. Failures cannot win selection or satisfy a fitness target. A run with no valid evaluation returns an explicit failure.
- Equal seeds and deterministic callbacks produce equal search results. External services retain responsibility for their own reproducibility.

**Responsibility boundary**

| Owner | Responsibility |
| --- | --- |
| `jido_evolve` | GA, general operators, candidate/evaluation records, run control, results, and telemetry |
| Application or `jido_htn` | Domain validity, scoring, domain operators, fixed evaluation cases, acceptance, and promotion |
| Optional future model optimizer | Reflection, model calls, trace selection, model cost accounting, and its own search schedule |

The existing `Jido.HTN.Learning.Evolver` is the integration case. Keep acceptance cases outside the candidate that can be changed. Keep search transitions separate from evaluation execution internally; defer a public general algorithm interface until a second implementation establishes its requirements.

**Deferred**

Multi-objective/Pareto search, native GEPA, additional numerical algorithms, MAP-Elites, islands, GPU or distributed execution, automatic caching, and persistent checkpoint/resume are outside this release. Remove or deprecate unused options that imply these capabilities exist.

Agent execution, DSPy-style program construction, generated-code execution environments, model training, and automatic deployment belong to application or adapter packages. Do not create those packages as part of this work.

DEAP supports the choice of replaceable operators. pymoo provides a reference for separating search from evaluation. [DEAP overview](https://deap.readthedocs.io/en/master/overview.html), [pymoo execution interfaces](https://pymoo.org/algorithms/usage.html)

GEPA supports preserving evaluation feedback, but needs its own search schedule and archive. A model-based mutation callback alone does not implement GEPA. DSPy is a broader program framework that offers several optimizers. Neither defines the scope of this GA package. [GEPA algorithm](https://dspy.ai/api/optimizers/GEPA/overview/), [DSPy optimizer guide](https://dspy.ai/diving-deeper/choosing-an-optimizer/)

**Completion checks**

1. Correct the engine and operator defects from the code review. Add regression tests for terminal results, failed evaluations, duplicates, budgets, seeds, empty inputs, and schema options.
2. Verify all supported representations through the public API. Include a known-optimum classical fixture, a structured configuration fixture, and an HTN integration test.
3. Test retained feedback with deterministic callbacks and no model dependency. Verify cancellation and timeout cleanup.
4. Pass package quality checks. Document both entry points, stop behavior, and one custom-operator example. Document breaking changes to generation counts, state, and callbacks; the manifest already declares 1.0.0.

After this release, choose one expansion only when a named consumer and a measurable acceptance test justify it. An optional experiment can compare Python GEPA with simple mutation and reflective hill climbing under equal evaluation budgets, with reflection cost reported separately. That experiment does not block this release.
