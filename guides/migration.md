# Migration for the next release

The manifest currently declares 1.0.0. These changes are pending release and
include breaking behavior. Select the release version before publishing.

- `generations: N` now means N breeding transitions after generation 0. A full
  stream can contain N + 1 states. Set N to one less than an old state count if
  that count must stay fixed. Initial and later successful states are included.
- Stream construction is lazy. Evaluation side effects occur during consumption.
- `run/1` returns the best valid result seen across the run, even if the final
  generation is worse. `evolve/1` still returns states; invalid options raise.
- `population_size` must match the initial list. Omit it in config options to
  infer the size. Duplicate values remain separate members.
- Failed evaluations no longer receive zero. An absent best score is `nil`.
  Inspect `state.evaluations` for failures. `state.scores` remains a lossy view
  keyed by candidate value; it is not used for selection or elitism.
- Custom `select/4` callbacks now receive and return member IDs. Their score map
  contains utility scores, with higher values always preferred. Use the
  `:evaluations` option for candidate values and raw scores. Return exactly the
  requested count. Crossover still receives candidate values and a config map.
- Put operator settings in `mutation_opts`, `selection_opts`, or `crossover_opts`.
  HParams requires `mutation_opts: [schema: schema]`. Fitness context is separate.
  Schemas reject invalid specifications; ranges must be ascending with step one.
- `mutate_with_feedback/3` is now used when a selected parent has feedback.
  Mutation receives the source record in `:parent_evaluation`.
- Diversity is off by default and returns `nil` when disabled. Enable
  `diversity_enabled: true` to use the Evolvable distance protocol.
- `no_improvement` counts transitions since the best score last improved. It no
  longer estimates variance over a truncated score history.
- Unknown public and config options are rejected. Unused `checkpoint_interval`
  and ineffective `selection_pressure`/tournament `pressure` were removed.
  Use `tournament_size` to control selection strength.
- Text and Random mutation now apply `strength` as a multiplier on the mutation
  probability. Its direct-call default is 1.0. AdaptiveText uses `rate` unless
  `high_rate` is supplied; its low rate is capped at the high rate.
- Seed behavior changed to isolate each run and its evaluation tasks. Sequences
  from the old engine are not retained.
- Callbacks that own detached work must use `Jido.Evolve.Cleanup.register/1` or
  provide an external owner. Worker `after` blocks cannot run after a forced
  stop. Registered cleanup also runs after normal completion. It has a separate
  positive, finite `cleanup_timeout` budget (default: 1,000 milliseconds).
  Cleanup failures invalidate the evaluation and retain its original outcome.

The adjacent HTN consumer can test this checkout with:

```bash
JIDO_EVOLVE_PATH=../jido_evolve mix deps.get
JIDO_EVOLVE_PATH=../jido_evolve mix test test/jido_htn/learning/evolver_test.exs
```

HTN freezes evaluation cases before search and uses them again for acceptance.
Its trace includes generation 0. Its promotion policy remains application-owned.
