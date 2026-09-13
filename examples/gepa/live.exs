evolve_path = Path.expand("../..", __DIR__)

req_llm =
  case System.get_env("REQ_LLM_PATH") do
    nil -> {:req_llm, "== 1.21.1"}
    path -> {:req_llm, path: Path.expand(path)}
  end

Mix.install([
  {:jido_evolve, path: evolve_path},
  req_llm
])

Code.require_file("search.exs", __DIR__)
Code.require_file("routing.exs", __DIR__)

alias GEPAExample.{Models, Routing, Search}

if "--check" in System.argv() do
  {:ok, _context} =
    ReqLLM.Context.normalize([
      %{role: :system, content: "Return only the label."},
      %{role: :user, content: "I need a refund."}
    ])

  IO.puts("ReqLLM and example modules loaded. Message format checked. No model requests sent.")
else
  task_model = System.fetch_env!("TASK_MODEL")
  reflection_model = System.fetch_env!("REFLECTION_MODEL")

  generate = fn model ->
    fn messages ->
      with {:ok, response} <- ReqLLM.generate_text(model, messages, max_tokens: 1024) do
        case ReqLLM.Response.text(response) do
          text when is_binary(text) -> {:ok, text}
          _ -> {:error, :missing_text}
        end
      end
    end
  end

  evaluate = Models.evaluator(generate.(task_model))
  reflect = Models.reflector(generate.(reflection_model))
  data = Routing.data()

  {:ok, result} =
    Search.run(
      seed_candidate: Routing.seed(),
      trainset: data.train,
      valset: data.validation,
      evaluate: evaluate,
      reflect: reflect,
      max_evaluations: 60,
      max_reflections: 4,
      max_concurrency: 2,
      evaluation_timeout: 60_000,
      reflection_timeout: 90_000
    )

  {:ok, baseline} = Search.evaluate_cases(Routing.seed(), data.test, evaluate, evaluation_timeout: 60_000)
  {:ok, final} = Search.evaluate_cases(result.best_candidate, data.test, evaluate, evaluation_timeout: 60_000)

  IO.inspect(result.best_candidate, label: "Selected prompt")
  IO.inspect(result.trace, label: "Search trace", limit: :infinity)

  IO.inspect(
    %{
      validation_score: result.best_score,
      seed_test_score: Enum.sum(Enum.map(baseline, & &1.score)) / length(baseline),
      best_test_score: Enum.sum(Enum.map(final, & &1.score)) / length(final),
      search_metric_calls: result.metric_calls,
      reflection_calls: result.reflection_calls,
      final_test_calls: length(baseline) + length(final),
      stop_reason: result.stop_reason
    },
    label: "Measured result"
  )
end
