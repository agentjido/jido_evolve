defmodule Jido.Evolve.Engine do
  @moduledoc "A lazy generational genetic algorithm with bounded evaluation."

  alias Jido.Evolve.{Config, Error, Evaluator, Options, Random, State}

  @doc "Build a stream. `generations` counts transitions after generation 0."
  @spec evolve(list(), Config.t(), module(), keyword()) :: Enumerable.t()
  def evolve(population, %Config{} = config, fitness, opts \\ []) do
    if not is_list(opts) or not Keyword.keyword?(opts) do
      raise Error.validation_error("engine options must be a keyword list")
    end

    normalized = Options.new!(Keyword.merge(opts, initial_population: population, config: config, fitness: fitness))
    stream(normalized)
  end

  @doc false
  @spec stream(Options.t()) :: Enumerable.t()
  def stream(opts) do
    Stream.resource(
      fn ->
        deadline = if opts.config.deadline_ms, do: System.monotonic_time(:millisecond) + opts.config.deadline_ms

        emit(opts.config, [:evolution, :start], %{population_size: length(opts.initial_population)}, %{
          config: opts.config
        })

        {nil, Random.seed(opts.config.random_seed), deadline}
      end,
      fn
        {%State{stop_reason: reason}, _, _} = resource when reason != nil ->
          {:halt, resource}

        {previous, random, deadline} ->
          {state, next_random} = Random.with_state(random, fn -> advance(previous, opts, deadline) end)
          {[state], {state, next_random, deadline}}
      end,
      fn {state, _, _} ->
        emit(opts.config, [:evolution, :stop], %{generation: if(state, do: state.generation)}, %{state: state})
      end
    )
  end

  @doc "Perform one transition from an evaluated state."
  @spec evolution_step(State.t(), module(), module(), module(), module(), map()) :: State.t()
  def evolution_step(state, fitness, mutation, selection, crossover, context) do
    opts =
      Options.new!(
        initial_population: state.population,
        config: state.config,
        fitness: fitness,
        mutation: mutation,
        selection: selection,
        crossover: crossover,
        context: context
      )

    advance(state, opts, nil)
  end

  defp advance(nil, opts, deadline) do
    opts.initial_population |> State.new(opts.config) |> evaluate(opts, deadline) |> finish()
  end

  defp advance(state, opts, deadline) do
    case Evaluator.stop_reason(opts, deadline) do
      nil ->
        state
        |> State.next_generation(breed(state, opts))
        |> evaluate(opts, deadline)
        |> finish()

      reason ->
        %{state | stop_reason: reason}
    end
  end

  defp evaluate(state, opts, deadline) do
    emit(state.config, [:generation, :start], %{generation: state.generation}, %{})
    emit(state.config, [:evaluation, :start], %{population_size: length(state.population)}, %{})
    {records, attempts, reason} = Evaluator.evaluate(state.population, state.generation, opts, deadline)
    state = State.update_evaluations(state, records, attempts, reason) |> State.calculate_diversity()
    emit(state.config, [:evaluation, :stop], %{evaluated_count: attempts}, %{evaluations: records})

    emit(state.config, [:generation, :stop], %{generation: state.generation, best_score: state.best_score}, %{
      state: state
    })

    state
  end

  defp finish(%State{stop_reason: reason} = state) when reason != nil, do: state

  defp finish(state) do
    reason =
      cond do
        not Enum.any?(state.evaluations, &(&1.status == :ok)) ->
          :no_valid_candidates

        State.terminated?(state) ->
          :termination_criterion

        state.generation >= state.config.generations ->
          :generations

        state.config.max_evaluations != nil and
            state.evaluation_count + state.config.population_size > state.config.max_evaluations ->
          :max_evaluations

        true ->
          nil
      end

    %{state | stop_reason: reason}
  end

  defp breed(state, opts) do
    valid = Enum.filter(state.evaluations, &(&1.status == :ok))
    if valid == [], do: raise(Error.execution_error("cannot breed without valid evaluations"))
    order = if state.config.objective == :maximize, do: :desc, else: :asc
    elites = valid |> Enum.sort_by(& &1.score, order) |> Enum.take(Config.elite_count(state.config))
    needed = state.config.population_size - length(elites)
    offspring = if needed == 0, do: [], else: offspring(valid, needed, state, opts)
    Enum.map(elites, & &1.entity) ++ offspring
  end

  defp offspring(valid, needed, state, opts) do
    records = Map.new(valid, &{&1.id, &1})

    scores =
      Map.new(valid, fn record ->
        score = if state.config.objective == :maximize, do: record.score, else: -record.score
        {record.id, score}
      end)

    selection_opts = Keyword.merge([tournament_size: state.config.tournament_size], opts.selection_opts)
    selection_opts = Keyword.put(selection_opts, :evaluations, records)
    count = 2 * div(needed + 1, 2)
    parents = opts.selection.select(Enum.map(valid, & &1.id), scores, count, selection_opts)

    if not is_list(parents) or length(parents) != count or Enum.any?(parents, &(not Map.has_key?(records, &1))) do
      raise Error.execution_error("selection must return the requested count of valid member IDs")
    end

    parents
    |> Enum.map(&Map.fetch!(records, &1))
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn [a, b] ->
      {child1, child2} =
        if :rand.uniform() < state.config.crossover_rate do
          opts.crossover.crossover(
            a.entity,
            b.entity,
            Map.merge(Map.from_struct(state.config), Map.new(opts.crossover_opts))
          )
        else
          {a.entity, b.entity}
        end

      [{child1, a}, {child2, b}]
    end)
    |> Enum.take(needed)
    |> Enum.map(fn {child, parent} -> mutate(child, parent, state, opts) end)
  end

  defp mutate(child, parent, state, opts) do
    strength =
      if function_exported?(opts.mutation, :mutation_strength, 1),
        do: opts.mutation.mutation_strength(state.generation),
        else: 1.0

    mutation_opts =
      Keyword.merge(
        [rate: state.config.mutation_rate, strength: strength, best_fitness: state.best_score],
        opts.mutation_opts
      )

    mutation_opts = Keyword.put(mutation_opts, :parent_evaluation, parent)

    result =
      if parent.feedback != nil and function_exported?(opts.mutation, :mutate_with_feedback, 3) do
        opts.mutation.mutate_with_feedback(child, parent.feedback, mutation_opts)
      else
        opts.mutation.mutate(child, mutation_opts)
      end

    case result do
      {:ok, entity} -> entity
      {:error, _reason} -> child
      other -> raise Error.execution_error("invalid mutation result", %{result: other})
    end
  end

  defp emit(%Config{metrics_enabled: true}, event, measurements, metadata) do
    :telemetry.execute([:jido_evolve | event], measurements, metadata)
  end

  defp emit(_config, _event, _measurements, _metadata), do: :ok
end
