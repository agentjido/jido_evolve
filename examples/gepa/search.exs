defmodule GEPAExample.CaseFitness do
  @moduledoc "Run one candidate on one fixed case through Jido.Evolve."
  use Jido.Evolve.Fitness

  @impl true
  @spec evaluate({map(), map()}, map()) :: Jido.Evolve.Fitness.eval_result()
  def evaluate({candidate, item}, %{evaluate: evaluate}), do: evaluate.(candidate, item)
end

defmodule GEPAExample.Search do
  @moduledoc """
  An example of the core GEPA search steps. This is not a public package API.

  Each candidate is a map of named text components. Training cases supply feedback.
  Validation cases determine the archive, parent selection, and final result.
  Test cases are not accepted by this API. All scores must be in the range 0..1.

  This example has no merge, cache, partial validation, or persistent resume.
  """

  @type candidate :: %{required(String.t()) => String.t()}
  @type result :: map()

  @doc "Run a bounded reflective search. See guides/gepa-examples.md for the callbacks."
  @spec run(keyword()) :: {:ok, result()} | {:error, map()}
  def run(opts) do
    config = Map.new(opts)

    config =
      Map.merge(
        %{
          batch_size: 3,
          max_evaluations: 120,
          max_reflections: 12,
          max_concurrency: 4,
          evaluation_timeout: 30_000,
          reflection_timeout: 60_000,
          cleanup_timeout: 1000,
          seed: 42,
          selection: :pareto
        },
        config
      )

    with :ok <- validate(config) do
      state = %{
        archive: [],
        trace: [],
        metric_calls: 0,
        reflection_calls: 0,
        iteration: 0,
        rng: :rand.seed_s(:exsss, config.seed)
      }

      case evaluate(config.seed_candidate, config.valset, config, state, :seed_validation) do
        {:ok, records, state} ->
          seed = entry(0, config.seed_candidate, nil, records)
          iterate(%{state | archive: [seed]}, config)

        {:error, error, state} ->
          failed(error, state)
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  @doc "Evaluate fixed cases with the same timeout, concurrency, and scoring rules as search."
  @spec evaluate_cases(candidate(), [map()], function(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def evaluate_cases(candidate, cases, evaluate, opts \\ []) do
    result =
      Jido.Evolve.run(
        initial_population: Enum.map(cases, &{candidate, &1}),
        fitness: GEPAExample.CaseFitness,
        context: %{evaluate: evaluate},
        config: [
          generations: 0,
          max_concurrency: Keyword.get(opts, :max_concurrency, 4),
          evaluation_timeout: Keyword.get(opts, :evaluation_timeout, 30_000),
          cleanup_timeout: Keyword.get(opts, :cleanup_timeout, 1000),
          random_seed: 42
        ]
      )

    case result do
      {:ok, result} -> checked_records(result.state.evaluations)
      {:error, error} -> {:error, error}
    end
  end

  @doc "List every candidate that ties for the best score on each validation case."
  @spec frontier([map()]) :: map()
  def frontier([]), do: %{}

  def frontier([first | _] = archive) do
    Map.new(first.validation_scores, fn {case_id, _score} ->
      best = archive |> Enum.map(&Map.fetch!(&1.validation_scores, case_id)) |> Enum.max()
      ids = for item <- archive, item.validation_scores[case_id] == best, do: item.id
      {case_id, ids}
    end)
  end

  defp iterate(state, config) do
    batch_size = min(config.batch_size, length(config.trainset))
    reserved = 2 * batch_size + length(config.valset)

    cond do
      state.reflection_calls >= config.max_reflections ->
        {:ok, result(state, :max_reflections)}

      state.metric_calls + reserved > config.max_evaluations ->
        {:ok, result(state, :max_evaluations)}

      true ->
        {parent, rng} = select_parent(state.archive, state.rng, config.selection)
        {batch, rng} = sample(config.trainset, batch_size, rng)
        components = config.seed_candidate |> Map.keys() |> Enum.sort()
        component = Enum.at(components, rem(state.iteration, length(components)))
        state = %{state | iteration: state.iteration + 1, rng: rng}
        step(state, config, parent, component, batch)
    end
  end

  defp step(state, config, parent, component, batch) do
    case evaluate(parent.candidate, batch, config, state, :parent_train) do
      {:ok, records, state} ->
        event = %{
          iteration: state.iteration,
          parent_id: parent.id,
          component: component,
          train_ids: Enum.map(batch, & &1.id),
          parent_score: mean(records)
        }

        if event.parent_score == 1.0 do
          continue(state, config, Map.put(event, :status, :perfect_batch))
        else
          propose(state, config, parent, component, records, batch, event)
        end

      {:error, error, state} ->
        failed(error, state)
    end
  end

  defp propose(state, config, parent, component, records, batch, event) do
    state = %{state | reflection_calls: state.reflection_calls + 1}

    case reflect(config, parent.candidate, component, records) do
      {:ok, text} when is_binary(text) and byte_size(text) > 0 and byte_size(text) <= 16_000 ->
        candidate = Map.put(parent.candidate, component, text)

        if Enum.any?(state.archive, &(&1.candidate == candidate)) do
          continue(state, config, Map.put(event, :status, :duplicate))
        else
          trial(state, config, parent, candidate, batch, event)
        end

      other ->
        failed({:reflection_failed, other}, state)
    end
  end

  defp trial(state, config, parent, candidate, batch, event) do
    case evaluate(candidate, batch, config, state, :proposal_train) do
      {:ok, records, state} ->
        event = Map.put(event, :proposal_score, mean(records))

        if event.proposal_score > event.parent_score do
          validate_proposal(state, config, parent, candidate, event)
        else
          continue(state, config, Map.put(event, :status, :rejected))
        end

      {:error, error, state} ->
        failed(error, state)
    end
  end

  defp validate_proposal(state, config, parent, candidate, event) do
    case evaluate(candidate, config.valset, config, state, :proposal_validation) do
      {:ok, records, state} ->
        item = entry(length(state.archive), candidate, parent.id, records)
        state = %{state | archive: state.archive ++ [item]}
        event = Map.merge(event, %{status: :accepted, candidate_id: item.id, validation_score: item.validation_score})
        continue(state, config, event)

      {:error, error, state} ->
        failed(error, state)
    end
  end

  defp continue(state, config, event) do
    event = Map.merge(event, Map.take(state, [:metric_calls, :reflection_calls]))
    iterate(%{state | trace: state.trace ++ [event]}, config)
  end

  defp evaluate(candidate, cases, config, state, stage) do
    state = %{state | metric_calls: state.metric_calls + length(cases)}

    opts = Map.take(config, [:max_concurrency, :evaluation_timeout, :cleanup_timeout]) |> Map.to_list()

    case evaluate_cases(candidate, cases, config.evaluate, opts) do
      {:ok, records} -> {:ok, records, state}
      {:error, error} -> {:error, {:evaluation_failed, stage, error}, state}
    end
  end

  defp checked_records(evaluations) do
    if Enum.all?(evaluations, &(&1.status == :ok and &1.score >= 0 and &1.score <= 1)) do
      records =
        Enum.map(evaluations, fn evaluation ->
          {_candidate, item} = evaluation.entity

          %{
            case_id: item.id,
            input: item.input,
            score: evaluation.score,
            feedback: evaluation.feedback,
            metadata: evaluation.metadata
          }
        end)

      {:ok, records}
    else
      {:error, {:invalid_evaluations, evaluations}}
    end
  end

  defp reflect(config, candidate, component, records) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      task =
        Jido.Evolve.Callback.async(
          supervisor,
          fn -> config.reflect.(candidate, component, records) end,
          System.monotonic_time(:millisecond) + config.reflection_timeout,
          config.cleanup_timeout
        )

      case Jido.Evolve.Callback.await(task) do
        {:ok, reply} -> reply
        {:error, reason} -> {:error, reason}
      end
    after
      Supervisor.stop(supervisor)
    end
  end

  defp select_parent(archive, rng, :current_best), do: {Enum.max_by(archive, & &1.validation_score), rng}

  defp select_parent(archive, rng, :pareto) do
    weighted_ids = archive |> frontier() |> Enum.sort() |> Enum.flat_map(fn {_id, ids} -> ids end)
    {index, rng} = :rand.uniform_s(length(weighted_ids), rng)
    id = Enum.at(weighted_ids, index - 1)
    {Enum.find(archive, &(&1.id == id)), rng}
  end

  defp sample(cases, size, rng) do
    {ranked, rng} =
      Enum.map_reduce(cases, rng, fn item, rng ->
        {weight, rng} = :rand.uniform_s(rng)
        {{weight, item}, rng}
      end)

    {ranked |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(size) |> Enum.map(&elem(&1, 1)), rng}
  end

  defp entry(id, candidate, parent_id, records) do
    %{
      id: id,
      candidate: candidate,
      parent_id: parent_id,
      validation_score: mean(records),
      validation_scores: Map.new(records, &{&1.case_id, &1.score})
    }
  end

  defp mean(records), do: Enum.sum(Enum.map(records, & &1.score)) / length(records)

  defp result(state, stop_reason) do
    best = Enum.max_by(state.archive, & &1.validation_score, fn -> nil end)

    %{
      best_candidate: if(best, do: best.candidate),
      best_score: if(best, do: best.validation_score),
      best_id: if(best, do: best.id),
      archive: state.archive,
      frontier: frontier(state.archive),
      trace: state.trace,
      metric_calls: state.metric_calls,
      reflection_calls: state.reflection_calls,
      stop_reason: stop_reason
    }
  end

  defp failed(error, state), do: {:error, %{reason: error, partial_result: result(state, :error)}}

  defp validate(config) do
    required = [:seed_candidate, :trainset, :valset, :evaluate, :reflect]

    allowed =
      required ++
        [
          :batch_size,
          :max_evaluations,
          :max_reflections,
          :max_concurrency,
          :evaluation_timeout,
          :reflection_timeout,
          :cleanup_timeout,
          :seed,
          :selection
        ]

    cond do
      Enum.any?(Map.keys(config), &(&1 not in allowed)) -> {:error, :unknown_option}
      not Enum.all?(required, &Map.has_key?(config, &1)) -> {:error, :missing_option}
      not candidate?(config.seed_candidate) -> {:error, :invalid_candidate}
      not cases?(config.trainset) or not cases?(config.valset) -> {:error, :invalid_cases}
      not is_function(config.evaluate, 2) or not is_function(config.reflect, 3) -> {:error, :invalid_callback}
      not positive_limits?(config) -> {:error, :invalid_limit}
      config.max_evaluations < length(config.valset) -> {:error, :budget_smaller_than_validation}
      not is_integer(config.seed) -> {:error, :invalid_seed}
      config.selection not in [:pareto, :current_best] -> {:error, :invalid_selection}
      duplicate_ids?(config.trainset ++ config.valset) -> {:error, :overlapping_or_duplicate_case_ids}
      true -> :ok
    end
  end

  defp candidate?(value) when is_map(value) and map_size(value) > 0 do
    Enum.all?(value, fn {key, text} -> is_binary(key) and is_binary(text) end)
  end

  defp candidate?(_value), do: false

  defp cases?(items) when is_list(items) and items != [] do
    Enum.all?(items, fn
      %{id: id, input: input} -> is_binary(id) and is_binary(input)
      _ -> false
    end)
  end

  defp cases?(_items), do: false

  defp duplicate_ids?(items), do: length(Enum.uniq_by(items, & &1.id)) != length(items)

  defp positive_limits?(config) do
    positive = [
      :batch_size,
      :max_evaluations,
      :max_concurrency,
      :evaluation_timeout,
      :reflection_timeout,
      :cleanup_timeout
    ]

    Enum.all?(positive, &(is_integer(config[&1]) and config[&1] > 0)) and
      is_integer(config.max_reflections) and config.max_reflections >= 0
  end
end
