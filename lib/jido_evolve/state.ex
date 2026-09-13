defmodule Jido.Evolve.State do
  @moduledoc """
  Represents the state of an evolutionary algorithm at a given generation.

  This structure tracks the current population, their fitness scores,
  and metadata about the evolution process.
  """

  alias Jido.Evolve.{Config, Evaluation, Evolvable, Error}

  @schema Zoi.struct(
            __MODULE__,
            %{
              population: Zoi.list(Zoi.any()) |> Zoi.default([]),
              scores: Zoi.map() |> Zoi.default(%{}),
              generation: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
              best_entity: Zoi.any() |> Zoi.nullish(),
              best_score: Zoi.number() |> Zoi.nullish(),
              average_score: Zoi.number() |> Zoi.default(0.0),
              diversity: Zoi.number() |> Zoi.nullish(),
              fitness_history: Zoi.list(Zoi.number()) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{}),
              evaluations: Zoi.list(Zoi.any()) |> Zoi.default([]),
              best_evaluation: Zoi.any() |> Zoi.nullish(),
              evaluation_count: Zoi.integer() |> Zoi.default(0),
              failure_count: Zoi.integer() |> Zoi.default(0),
              stagnant_generations: Zoi.integer() |> Zoi.default(0),
              complete: Zoi.boolean() |> Zoi.default(false),
              last_complete_population: Zoi.any() |> Zoi.nullish(),
              last_complete_generation: Zoi.integer() |> Zoi.nullish(),
              stop_reason: Zoi.atom() |> Zoi.nullish(),
              config: Config.schema()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Create a new state from attributes.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs_map = if is_list(attrs), do: Map.new(attrs), else: attrs

    case Zoi.parse(@schema, attrs_map) do
      {:ok, state} ->
        {:ok, state}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Create a new initial state from a population and config.

  ## Examples

      iex> config = Jido.Evolve.Config.new!()
      iex> state = Jido.Evolve.State.new(["a", "b", "c"], config)
      iex> state.population
      ["a", "b", "c"]
  """
  @spec new(list(any()), Config.t()) :: t()
  def new(population, %Config{} = config) do
    new!(%{population: population, config: config})
  end

  @doc """
  Create a new state, raising on validation errors.
  """
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, state} -> state
      {:error, error} -> raise Error.validation_error("invalid state", %{errors: error})
    end
  end

  @doc """
  Update the state with new fitness scores.

  This recalculates the best entity, best score, and average score.
  """
  @spec update_scores(t(), map()) :: t()
  def update_scores(%__MODULE__{} = state, scores) when is_map(scores) do
    records =
      state.population
      |> Enum.with_index()
      |> Enum.flat_map(fn {entity, index} ->
        case Map.fetch(scores, entity) do
          {:ok, score} when is_number(score) -> [Evaluation.new({state.generation, index}, entity, {:ok, score})]
          _ -> []
        end
      end)

    update_evaluations(state, records, length(records), nil)
  end

  @doc "Store member evaluations and update the best result seen across the run."
  @spec update_evaluations(t(), list(Evaluation.t()), non_neg_integer(), atom() | nil) :: t()
  def update_evaluations(state, records, attempts, stop_reason) do
    valid = Enum.filter(records, &(&1.status == :ok))
    best = Enum.reduce(valid, nil, &better(&1, &2, state.config.objective))
    overall = if best, do: better(best, state.best_evaluation, state.config.objective), else: state.best_evaluation
    improved = overall != state.best_evaluation
    complete = length(records) == length(state.population) and not Enum.any?(records, &(&1.status == :cancelled))
    average = if valid == [], do: 0.0, else: Enum.sum(Enum.map(valid, & &1.score)) / length(valid)

    %{
      state
      | evaluations: records,
        scores: Map.new(valid, &{&1.entity, &1.score}),
        best_entity: if(best, do: best.entity),
        best_score: if(best, do: best.score),
        best_evaluation: overall,
        average_score: average,
        evaluation_count: state.evaluation_count + attempts,
        failure_count: state.failure_count + Enum.count(records, &(&1.status != :ok)),
        stagnant_generations: if(improved or state.generation == 0, do: 0, else: state.stagnant_generations + 1),
        complete: complete,
        last_complete_population: if(complete, do: state.population, else: state.last_complete_population),
        last_complete_generation: if(complete, do: state.generation, else: state.last_complete_generation),
        stop_reason: stop_reason
    }
  end

  defp better(record, nil, _objective), do: record
  defp better(record, previous, :maximize), do: if(record.score > previous.score, do: record, else: previous)
  defp better(record, previous, :minimize), do: if(record.score < previous.score, do: record, else: previous)

  @doc """
  Update the population and advance the generation counter.
  """
  @spec next_generation(t(), list(any())) :: t()
  def next_generation(%__MODULE__{} = state, new_population) do
    new_history =
      if state.best_score == nil,
        do: state.fitness_history,
        else: Enum.take([state.best_score | state.fitness_history], 100)

    %{
      state
      | population: new_population,
        generation: state.generation + 1,
        scores: %{},
        best_entity: nil,
        best_score: nil,
        evaluations: [],
        complete: false,
        stop_reason: nil,
        average_score: 0.0,
        fitness_history: new_history
    }
  end

  @doc """
  Calculate diversity of the current population.

  This is useful for monitoring convergence and maintaining diversity.
  """
  @spec calculate_diversity(t()) :: t()
  def calculate_diversity(%__MODULE__{config: %Config{diversity_enabled: false}} = state), do: %{state | diversity: nil}

  def calculate_diversity(%__MODULE__{population: population} = state) do
    diversity = calculate_population_diversity(population)
    %{state | diversity: diversity}
  end

  @doc """
  Add metadata to the state.
  """
  @spec put_metadata(t(), atom() | String.t(), term()) :: t()
  def put_metadata(%__MODULE__{metadata: metadata} = state, key, value) do
    %{state | metadata: Map.put(metadata, key, value)}
  end

  @doc """
  Check if termination criteria are met.
  """
  @spec terminated?(t()) :: boolean()
  def terminated?(%__MODULE__{config: config} = state) do
    criteria = config.termination_criteria
    Enum.any?(criteria, &check_criterion(state, &1))
  end

  defp calculate_population_diversity(population) when length(population) < 2, do: 0.0

  defp calculate_population_diversity(population) do
    members = Enum.with_index(population)

    pairs =
      if length(population) < 10 do
        for {a, i} <- members, {b, j} <- members, i < j, do: {a, b}
      else
        Enum.map(1..min(1000, length(population) * 10), fn _ ->
          [{a, _}, {b, _}] = Enum.take_random(members, 2)
          {a, b}
        end)
      end

    Enum.sum(Enum.map(pairs, fn {a, b} -> Evolvable.similarity(a, b) end)) / length(pairs)
  end

  defp check_criterion(state, {:max_generations, max_gen}), do: state.generation >= max_gen
  defp check_criterion(%{best_score: nil}, {:target_fitness, _target}), do: false

  defp check_criterion(%{config: %{objective: :minimize}} = state, {:target_fitness, target}),
    do: state.best_score <= target

  defp check_criterion(state, {:target_fitness, target}), do: state.best_score >= target
  defp check_criterion(state, {:no_improvement, generations}), do: state.stagnant_generations >= generations
  defp check_criterion(_state, _criterion), do: false
end
