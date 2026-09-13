Code.require_file("search.exs", __DIR__)
Code.require_file("routing.exs", __DIR__)

alias GEPAExample.{Mock, Routing, Search}

data = Routing.data()

{:ok, result} =
  Search.run(
    seed_candidate: Routing.seed(),
    trainset: data.train,
    valset: data.validation,
    evaluate: &Mock.evaluate/2,
    reflect: &Mock.reflect/3,
    max_evaluations: 120,
    max_reflections: 12,
    seed: 42
  )

IO.puts("GEPA core steps in Elixir. Task and reflection are deterministic mocks.")
IO.inspect(result.trace, label: "Search trace", pretty: true, limit: :infinity)
IO.inspect(result.best_candidate, label: "Selected prompt")
IO.inspect(result.frontier, label: "Best candidate IDs per validation case")

{:ok, seed_test} = Search.evaluate_cases(Routing.seed(), data.test, &Mock.evaluate/2)
{:ok, best_test} = Search.evaluate_cases(result.best_candidate, data.test, &Mock.evaluate/2)

IO.inspect(
  %{
    seed_validation_score: hd(result.archive).validation_score,
    best_validation_score: result.best_score,
    seed_test_score: Enum.sum(Enum.map(seed_test, & &1.score)) / length(seed_test),
    best_test_score: Enum.sum(Enum.map(best_test, & &1.score)) / length(best_test),
    search_metric_calls: result.metric_calls,
    reflection_calls: result.reflection_calls,
    final_test_calls: length(seed_test) + length(best_test),
    stop_reason: result.stop_reason
  },
  label: "Result (fixture only; not a model benchmark)"
)
