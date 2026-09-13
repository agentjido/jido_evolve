# Getting started

Use `Jido.Evolve.run/1` for a final result or `Jido.Evolve.evolve/1` for progress.
Both use the same search engine. Required options are a non-empty
`:initial_population` and a `:fitness` module that exports `evaluate/2`.

## Configuration

Pass `:config` as a keyword list, map, or `Jido.Evolve.Config` struct.
When omitted from a keyword list or map, `population_size` is inferred from the
initial population. An explicit size must match that population.

| Option | Default | Meaning |
| --- | --- | --- |
| `generations` | 1000 | Maximum breeding transitions after generation 0; zero is valid |
| `objective` | `:maximize` | `:maximize` or `:minimize` |
| `mutation_rate` | 0.1 | Rate supplied to mutation; the operator defines its unit |
| `crossover_rate` | 0.7 | Probability per parent pair |
| `elitism_rate` | 0.05 | Fraction of valid members copied before breeding; any positive rate preserves at least one |
| `tournament_size` | 2 | Number of members compared per tournament |
| `max_evaluations` | `nil` | Maximum candidate evaluation attempts |
| `deadline_ms` | `nil` | Elapsed time limit from the start of stream consumption |
| `max_concurrency` | Scheduler count | Maximum active evaluation tasks |
| `evaluation_timeout` | 30,000 | Timeout per task in milliseconds; accepts `:infinity` |
| `cleanup_timeout` | 1,000 | Shared cleanup time limit per callback in milliseconds; must be positive and finite |
| `random_seed` | `nil` | Integer seed owned by this run |
| `diversity_enabled` | `false` | Measure distance using the Evolvable protocol |
| `metrics_enabled` | `true` | Emit telemetry events |
| `termination_criteria` | `[]` | `target_fitness`, `no_improvement`, or `max_generations` limits |

Each attempted evaluation costs one budget unit, including invalid results,
errors, timeouts, and interrupted tasks. Elite members are evaluated again.
The initial population must fit within the budget. A new generation starts only
when the remaining budget can cover its full population. There is no automatic
cache or retry.

`no_improvement: N` stops after N consecutive breeding transitions without a
strict improvement in the best score seen. It supports windows longer than 100.
`target_fitness` uses the configured objective direction.

## Evaluation records

```elixir
defmodule ConfigurationFitness do
  use Jido.Evolve.Fitness

  @impl true
  def evaluate(candidate, %{target: target}) do
    if candidate.width in 1..10 do
      {:ok, %{
        score: abs(candidate.width - target),
        metadata: %{target: target},
        feedback: %{next_width: target}
      }}
    else
      {:invalid, :width_out_of_bounds}
    end
  end
end
```

An evaluator can return `{:ok, number}`, `{:ok, %{score: number, ...}}`,
`{:invalid, reason}`, or `{:error, reason}`. Exceptions, exits, malformed results,
and timeouts become failed records. They cannot win selection or satisfy a target.

Each record has an ID `{generation, index}`, candidate `entity`, status, optional
score, metadata, feedback, error, and the original result map in `data`.
`state.evaluations` contains the records in population order. Equal values keep
separate IDs. `state.scores` is a compatibility view keyed by value; use evaluation
records when duplicate values can receive different scores.

## Custom mutation and feedback

```elixir
defmodule SetWidth do
  use Jido.Evolve.Mutation

  @impl true
  def mutate(candidate, opts) do
    {:ok, Map.put(candidate, :width, Keyword.fetch!(opts, :width))}
  end

  @impl true
  def mutate_with_feedback(candidate, feedback, _opts) do
    {:ok, Map.put(candidate, :width, feedback.next_width)}
  end

  @impl true
  @doc "Check the required width option before evaluation starts."
  @spec validate_opts(keyword()) :: :ok | {:error, String.t()}
  def validate_opts(opts) do
    if Keyword.get(opts, :width) in 1..10, do: :ok, else: {:error, "width must be in 1..10"}
  end
end

{:ok, result} = Jido.Evolve.run(
  initial_population: [%{width: 1}, %{width: 8}],
  fitness: ConfigurationFitness,
  context: %{target: 4},
  mutation: SetWidth,
  mutation_opts: [width: 4],
  crossover: Jido.Evolve.Crossover.MapUniform,
  config: [objective: :minimize, generations: 5, termination_criteria: [target_fitness: 0]]
)

IO.inspect(result.best_entity)
```

Mutation receives keyword options with rate, strength, current best fitness, and
`parent_evaluation`. If that parent has feedback, the engine calls
`mutate_with_feedback/3` when available. After crossover, this feedback still
belongs to the source parent, not to the untested child. An error tuple retains
the child unchanged. Invalid callback results raise an execution error.

Use `mutation_opts`, `selection_opts`, and `crossover_opts` for explicit operator
configuration. Optional `validate_opts/1` callbacks run before evaluation starts.
Required HParams schemas are checked at this stage.

Selection receives valid member IDs, a map of IDs to utility scores, the required
count, and keyword options. Larger utility is always better; the engine negates
scores for minimization. Raw evaluations are in `opts[:evaluations]`.
Return exactly the requested number of valid IDs, with replacement if needed.
Crossover receives two candidate values and a map formed from config plus
`crossover_opts`; return `{child1, child2}`.

## Streams and final results

```elixir
states = Jido.Evolve.evolve(options)

states
|> Stream.each(fn state -> IO.inspect({state.generation, state.best_score}) end)
|> Enum.reduce(nil, fn state, _previous -> state end)
```

Creating a stream starts no evaluation. Taking one state evaluates only generation
0. Each enumeration is a new run. The successful terminal generation is included.
Deadline or cancellation can also emit a terminal state with partial evaluations;
check `state.complete`. Cancellation between generations can return the previous
complete state again with a stop reason.

The final result reports the best valid evaluation seen, the last complete
population and generation, cumulative attempt and failure counts, and a stop
reason: `:generations`, `:max_evaluations`, `:termination_criterion`, `:deadline`,
`:cancelled`, or `:no_valid_candidates`. With no valid evaluation, `run/1` returns
an execution error with the result in `error.details.result`. Before any generation
completes, the result's population and generation are `nil`.

The engine retains current evaluation records, the best evaluation seen, and up
to 100 historical scores. Use external references for large traces. A caller that
collects every stream state also retains every collected evaluation record.

## Cancellation and reproducibility

```elixir
token = Jido.Evolve.Cancellation.new()
task = Task.async(fn -> Jido.Evolve.run(Keyword.put(options, :cancellation, token)) end)

Jido.Evolve.Cancellation.cancel(token)
result = Task.await(task, :infinity)
```

Cancellation and deadlines stop new evaluation scheduling and terminate the
run's active evaluation tasks. The check interval is approximately 5 milliseconds.
Each evaluation has a separate owner that enforces its timeout. Registered cleanup
finishes, fails, or reaches its time limit before the stream yields. Selection and
variation callbacks run synchronously and must return promptly. Tasks are not a
sandbox for generated code or a way to undo external side effects.

### Detached work and cleanup

A timeout kills the callback worker. Its `after` block cannot run. If the callback
starts detached work, such as a Harness run, register cleanup with
`Jido.Evolve.Cleanup.register/1`. The same API works in GEPA evaluation and
reflection callbacks.

```elixir
def evaluate(candidate, context) do
  run_id = MyClient.new_run_id()
  :ok = Jido.Evolve.Cleanup.register(fn _reason -> MyClient.cancel(run_id) end)
  MyClient.evaluate(run_id, candidate, context)
end
```

`MyClient` is an application adapter. Its cancellation function must return only
after the external work stops. Use a stable resource ID and register before
starting work when the client permits this. If a client returns its resource ID
only after startup, termination during startup can prevent registration. Cover
that gap with an external owner or a deadline enforced by the service.

The callback owner stores each function before registration returns. After the
worker stops, it starts all registered functions in separate processes. Each
function runs once per registration, including on normal completion. Functions
must be idempotent and must return `:ok` or `{:ok, value}`. They receive one of
`:completed`, `:timeout`, `:cancelled`, `:deadline`, `:owner_down`, or
`{:exit, reason}`. A returned evaluation error is a completed callback; a worker
process crash has an exit reason. When the caller dies, the callback owner still
runs cleanup. The reason can be `:owner_down` or an exit reason, depending on
which process stops first.

All functions for one callback run concurrently and share one `cleanup_timeout`
budget. At its end, unfinished cleanup processes are killed. Cancellation stops
all active workers before it waits for their cleanup. Cleanup can add up to one
cleanup budget, plus process scheduling time, after a callback timeout or run
deadline. The time spent in cleanup does not change a callback's finish timestamp.
An evaluation continues to occupy its concurrency slot until cleanup finishes.

A cleanup failure makes that evaluation fail with
`{:cleanup_failed, original_outcome, failures}` in its error field. Reflection
returns the same error in the partial search result. The error retains the
original outcome and each cleanup failure. A timeout is recorded as `:timeout`.
Do not treat a cleanup timeout as proof that external work stopped.

Register from the callback worker itself. Spawned processes do not inherit its
registration scope. Cleanup functions must not depend on the callback worker
or start unowned detached work. Unregistered resources, VM termination, and
services that ignore cancellation remain the application's responsibility.

The same seed, input order, callbacks, configuration, and OTP version produce the
same search results with deterministic callbacks. Run random state is separate
from caller random state. Evaluation tasks also receive repeatable seeds.
Remote services, callback side effects, and time limits can prevent exact replay.

Telemetry events use `[:jido_evolve, component, :start | :stop]`, where component
is `:evolution`, `:generation`, or `:evaluation`. Evaluation stop metadata includes
records. Evolution stop also fires when a consumer stops early.
