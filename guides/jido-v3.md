# Use with consolidated Jido v3

`jido_evolve` is a separate search library. Consolidated Jido v3 owns Actions,
Flows, Agents, Signals, and AI execution. Evolve owns candidate search, variation,
fitness records, budgets, and search results. It does not require Jido at runtime.
Applications can use both packages in one supervision tree.

## Dependency boundary

Evolve uses Zoi `~> 0.19.0`, Splode `~> 0.3.0`, and Telemetry `~> 1.3`.
These constraints overlap the local consolidated Jido v3 constraints. Evolve
calls no old `jido_action`, `jido_signal`, or `jido_ai` APIs. Do not add those
packages to connect Evolve to consolidated Jido.

This is a source-level compatibility boundary. Test the selected Jido version
and both packages together before release. Separate package tests do not prove
that a combined application resolves, compiles, and runs.

## Application-owned fitness adapter

Put the adapter in the application that depends on both packages. A fitness
callback can execute a Jido Flow and map its output to the Evolve score contract.
This example needs no model or network call:

```elixir
defmodule MyApp.ScoreCandidate do
  use Jido.Action, name: "score_candidate"

  @impl true
  def run(%{candidate: candidate}, _context) do
    {:ok, %{score: String.length(candidate)}}
  end
end

defmodule MyApp.ScoreFlow do
  use Jido.Flow, name: "score_candidate_flow"

  flow do
    step "score", action: MyApp.ScoreCandidate, params: %{candidate: input(:candidate)}
    output result("score")
  end
end

defmodule MyApp.FlowFitness do
  use Jido.Evolve.Fitness

  @impl true
  def evaluate(candidate, context) do
    case Jido.Exec.run(MyApp.ScoreFlow, %{candidate: candidate}, context) do
      {:ok, %{score: score}} when is_number(score) -> {:ok, score}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_flow_result, other}}
    end
  end
end

{:ok, result} = Jido.Evolve.run(
  initial_population: ["a", "abc", "ab"],
  fitness: MyApp.FlowFitness,
  context: %{},
  config: [generations: 0, max_evaluations: 3, random_seed: 42]
)

"abc" = result.best_entity
3 = result.best_score
```

Pass an explicit application context. Keep reference cases fixed across search
and acceptance. An application that uses `jido_eval` can call its public API in
the fitness callback and map the chosen metric to a numeric score. Evolve does
not select that metric or the release acceptance threshold.

## Runtime limits and promotion

Evolve limits evaluation attempts and callback time. A model budget is a separate
application concern. Bound model calls, tokens, and cost in the application.
For detached Jido or external runs, register cancellation through
`Jido.Evolve.Cleanup.register/1` as described in the
[callback guide](getting-started.md#detached-work-and-cleanup).

Search candidates should be data, such as prompt text or validated configuration.
The application validates the winning candidate and decides whether to store or
activate it. Evolve does not edit a running Agent or promote a candidate.

## Existing consumers

The workspace `jido_htn` package calls the Evolve API and pins a Git revision.
`jido_loom` also has an Evolve lock entry through its dependency tree. Changes to
Evolve callback or generation contracts require focused HTN tests and a separate
consumer update. This guide does not claim those consumers support Jido v3.
