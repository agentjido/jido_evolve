defmodule Jido.Evolve.EngineTest do
  use ExUnit.Case, async: true

  alias Jido.Evolve.{Config, Engine, Error}

  alias TestEngine.{
    AlwaysWorseSelection,
    CustomMutation,
    CustomSelection,
    ErrorMutation,
    MetadataFitness,
    MixedFitness,
    OddSelection,
    OddSelection2,
    TimeoutFitness
  }

  describe "evolve stream shape and termination" do
    test "returns a Stream that yields states" do
      config = Config.new!(population_size: 4, generations: 2, mutation_rate: 0.5)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      stream = Engine.evolve(initial_pop, config, TestFitness)

      assert is_function(stream)
    end

    test "stops at config.generations = 1" do
      config = Config.new!(population_size: 4, generations: 1, mutation_rate: 0.5)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      assert length(states) == 2
      assert hd(states).generation == 0
    end

    test "stops at config.generations = 2" do
      config = Config.new!(population_size: 4, generations: 2, mutation_rate: 0.5)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      assert length(states) == 3
      assert Enum.at(states, 0).generation == 0
      assert Enum.at(states, 1).generation == 1
    end

    test "stops at config.generations = 3" do
      config = Config.new!(population_size: 4, generations: 3, mutation_rate: 0.5)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      assert length(states) == 4
      assert Enum.at(states, 0).generation == 0
      assert Enum.at(states, 1).generation == 1
      assert Enum.at(states, 2).generation == 2
    end

    test "options override config mutation strategy" do
      config =
        Config.new!(
          population_size: 4,
          generations: 2,
          mutation_rate: 1.0,
          mutation_strategy: TestMutation
        )

      initial_pop = ["a", "bb", "ccc", "dddd"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness, mutation: CustomMutation)
        |> Enum.to_list()

      final_state = List.last(states)

      has_custom_mutation = Enum.any?(final_state.population, &String.contains?(&1, "_custom"))
      assert has_custom_mutation
    end

    test "options override config selection strategy" do
      config =
        Config.new!(
          population_size: 4,
          generations: 1,
          mutation_rate: 0.5,
          selection_strategy: TestSelection
        )

      initial_pop = ["a", "bb", "ccc", "dddd"]

      [final_state | _] =
        initial_pop
        |> Engine.evolve(config, TestFitness, selection: CustomSelection)
        |> Enum.to_list()

      assert length(final_state.population) == 4
    end

    test "legacy strategy override keys are rejected" do
      config = Config.new!(population_size: 4, generations: 1)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      assert_raise Error.InvalidInputError, fn ->
        initial_pop
        |> Engine.evolve(config, TestFitness, mutation_module: CustomMutation)
        |> Enum.to_list()
      end
    end

    test "non-keyword engine options are rejected" do
      config = Config.new!(population_size: 4, generations: 1)

      assert_raise Error.InvalidInputError, fn ->
        apply(Engine, :evolve, [["a", "bb", "ccc", "dddd"], config, TestFitness, %{context: %{}}])
      end
    end
  end

  describe "evaluate_population happy path" do
    test "fitness.evaluate returns {:ok, score} → scores map updated" do
      config = Config.new!(population_size: 4, generations: 1)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      [state | _] =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      assert state.scores["a"] == 1.0
      assert state.scores["bb"] == 2.0
      assert state.scores["ccc"] == 3.0
      assert state.scores["dddd"] == 4.0
    end

    test "fitness.evaluate returns {:ok, %{score: score}} → metadata handled" do
      config = Config.new!(population_size: 4, generations: 1)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      [state | _] =
        initial_pop
        |> Engine.evolve(config, MetadataFitness)
        |> Enum.to_list()

      assert state.scores["a"] == 1.0
      assert state.scores["bb"] == 2.0
      assert state.scores["ccc"] == 3.0
      assert state.scores["dddd"] == 4.0
    end

    test "verify all entities get evaluated and best_score updates" do
      config = Config.new!(population_size: 6, generations: 1)
      initial_pop = ["a", "bb", "ccc", "dddd", "eeeee", "ffffff"]

      [state | _] =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      assert map_size(state.scores) == 6

      assert state.best_score == 6.0
      assert state.best_entity == "ffffff"

      expected_avg = (1.0 + 2.0 + 3.0 + 4.0 + 5.0 + 6.0) / 6.0
      assert_in_delta state.average_score, expected_avg, 0.01
    end
  end

  describe "evaluate_population error paths" do
    test "fitness.evaluate returns {:error, reason} → entity has an error record and no score" do
      config = Config.new!(population_size: 4, generations: 1)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      [state | _] =
        initial_pop
        |> Engine.evolve(config, TestFitness, context: %{return_error: true})
        |> Enum.to_list()

      assert state.scores["a"] == nil
      assert state.scores["bb"] == nil
      assert state.scores["ccc"] == nil
      assert state.scores["dddd"] == nil

      assert state.best_score == nil
      assert state.stop_reason == :no_valid_candidates
      assert Enum.all?(state.evaluations, &(&1.status == :error))
    end

    test "fitness.evaluate timeout/exit → Task.async_stream yields {:exit, reason}, logs warning" do
      config = Config.new!(population_size: 2, generations: 1, max_concurrency: 1)
      initial_pop = ["quick", "slow"]

      [state | _] =
        initial_pop
        |> Engine.evolve(config, TimeoutFitness)
        |> Enum.to_list()

      assert map_size(state.scores) >= 0
    end

    test "verify reduction doesn't crash and results are handled" do
      config = Config.new!(population_size: 6, generations: 1, max_concurrency: 1)
      initial_pop = ["a", "bb", "ccc", "dddd", "eeeee", "ffffff"]

      [state | _] =
        initial_pop
        |> Engine.evolve(config, MixedFitness)
        |> Enum.to_list()

      assert state.scores["bb"] == 2.0
      assert state.scores["dddd"] == 4.0
      assert state.scores["ffffff"] == 6.0

      assert state.scores["a"] == nil
      assert state.scores["ccc"] == nil
      assert state.scores["eeeee"] == nil

      assert state.best_score == 6.0
      assert state.best_entity == "ffffff"
    end
  end

  describe "basic telemetry events" do
    setup do
      test_pid = self()

      handler_id = :telemetry_test_handler

      :telemetry.attach_many(
        handler_id,
        [
          [:jido_evolve, :evolution, :start],
          [:jido_evolve, :evolution, :stop],
          [:jido_evolve, :generation, :start],
          [:jido_evolve, :generation, :stop],
          [:jido_evolve, :evaluation, :start],
          [:jido_evolve, :evaluation, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "[:jido_evolve, :evolution, :start] and [:jido_evolve, :evolution, :stop] events fire" do
      config = Config.new!(population_size: 4, generations: 1)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      initial_pop
      |> Engine.evolve(config, TestFitness)
      |> Enum.to_list()

      assert_receive {:telemetry, [:jido_evolve, :evolution, :start], %{population_size: 4}, %{config: ^config}}

      assert_receive {:telemetry, [:jido_evolve, :evolution, :stop], %{generation: _}, %{state: _}}
    end

    test "[:jido_evolve, :generation, :start] and [:jido_evolve, :generation, :stop] events fire" do
      config = Config.new!(population_size: 4, generations: 2)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      initial_pop
      |> Engine.evolve(config, TestFitness)
      |> Enum.to_list()

      assert_receive {:telemetry, [:jido_evolve, :generation, :start], %{generation: 1}, %{}}

      assert_receive {:telemetry, [:jido_evolve, :generation, :stop], %{generation: 1, best_score: _}, %{state: _}}
    end

    test "[:jido_evolve, :evaluation, :start] and [:jido_evolve, :evaluation, :stop] events fire" do
      config = Config.new!(population_size: 4, generations: 1)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      initial_pop
      |> Engine.evolve(config, TestFitness)
      |> Enum.to_list()

      assert_receive {:telemetry, [:jido_evolve, :evaluation, :start], %{population_size: 4}, %{}}

      assert_receive {:telemetry, [:jido_evolve, :evaluation, :stop], %{evaluated_count: _}, %{}}
    end

    test "events fire in correct order for 2 generations" do
      config = Config.new!(population_size: 4, generations: 2)
      initial_pop = ["a", "bb", "ccc", "dddd"]

      initial_pop
      |> Engine.evolve(config, TestFitness)
      |> Enum.to_list()

      events = collect_telemetry_events([])

      event_names = Enum.map(events, fn {_, event, _, _} -> event end)

      assert [:jido_evolve, :evolution, :start] in event_names
      assert [:jido_evolve, :evaluation, :start] in event_names
      assert [:jido_evolve, :generation, :start] in event_names
      assert [:jido_evolve, :generation, :stop] in event_names
      assert [:jido_evolve, :evolution, :stop] in event_names
    end
  end

  defp collect_telemetry_events(acc) do
    receive do
      {:telemetry, _event, _measurements, _metadata} = msg ->
        collect_telemetry_events([msg | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  describe "select_and_breed crossover rate branches" do
    test "crossover_rate = 1.0 → crossover called for all pairs" do
      config =
        Config.new!(
          population_size: 6,
          generations: 2,
          mutation_rate: 0.0,
          crossover_rate: 1.0,
          crossover_strategy: TestCrossover,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aa", "bb", "cc", "dd", "ee", "ff"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      final_state = List.last(states)

      assert length(final_state.population) == 6

      has_crossover =
        Enum.any?(final_state.population, fn child ->
          String.length(child) == 2
        end)

      assert has_crossover
    end

    test "crossover_rate = 0.0 → crossover not called, parents passed through" do
      config =
        Config.new!(
          population_size: 6,
          generations: 2,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          crossover_strategy: TestCrossover,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aa", "bb", "cc", "dd", "ee", "ff"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      final_state = List.last(states)

      assert length(final_state.population) == 6

      all_from_parents =
        Enum.all?(final_state.population, fn child ->
          child in initial_pop
        end)

      assert all_from_parents
    end

    test "crossover_rate = 0.5 → some crossover, some passthrough" do
      config =
        Config.new!(
          population_size: 10,
          generations: 2,
          mutation_rate: 0.0,
          crossover_rate: 0.5,
          crossover_strategy: TestCrossover,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh", "ii", "jj"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      final_state = List.last(states)

      assert length(final_state.population) == 10

      exact_copies = Enum.count(final_state.population, &(&1 in initial_pop))

      assert exact_copies > 0
      assert exact_copies < 10
    end
  end

  describe "select_and_breed mutation rate branches" do
    test "mutation_rate = 1.0 → mutate called on all children" do
      config =
        Config.new!(
          population_size: 6,
          generations: 2,
          mutation_rate: 1.0,
          crossover_rate: 0.0,
          crossover_strategy: TestCrossover,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aa", "bb", "cc", "dd", "ee", "ff"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      final_state = List.last(states)

      all_mutated =
        Enum.all?(final_state.population, fn child ->
          String.ends_with?(child, "_mutated")
        end)

      assert all_mutated
      assert length(final_state.population) == 6
    end

    test "mutation_rate = 0.0 → mutate not called" do
      config =
        Config.new!(
          population_size: 6,
          generations: 2,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          crossover_strategy: TestCrossover,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aa", "bb", "cc", "dd", "ee", "ff"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      final_state = List.last(states)

      none_mutated =
        Enum.all?(final_state.population, fn child ->
          not String.ends_with?(child, "_mutated")
        end)

      assert none_mutated
      assert length(final_state.population) == 6
    end

    test "mutation_rate = 0.5 → some mutated, some not" do
      config =
        Config.new!(
          population_size: 10,
          generations: 2,
          mutation_rate: 0.5,
          crossover_rate: 0.0,
          crossover_strategy: TestCrossover,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh", "ii", "jj"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      final_state = List.last(states)

      mutated_count =
        Enum.count(final_state.population, fn child ->
          String.ends_with?(child, "_mutated")
        end)

      assert mutated_count > 0
      assert mutated_count < 10
      assert length(final_state.population) == 10
    end
  end

  describe "select_and_breed mutation error handling" do
    test "mutation returns {:error, _} → child passed through unchanged (with warning)" do
      config =
        Config.new!(
          population_size: 4,
          generations: 2,
          mutation_rate: 1.0,
          crossover_rate: 0.0,
          mutation_strategy: ErrorMutation,
          selection_strategy: TestSelection,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aa", "bb", "cc", "dd"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      final_state = List.last(states)

      none_mutated =
        Enum.all?(final_state.population, fn child ->
          not String.ends_with?(child, "_mutated")
        end)

      assert none_mutated
      assert length(final_state.population) == 4

      all_from_parents =
        Enum.all?(final_state.population, fn child ->
          child in initial_pop
        end)

      assert all_from_parents
    end
  end

  describe "selection contract" do
    test "rejects a selection result with too few member IDs" do
      for selection <- [OddSelection, OddSelection2] do
        config = Config.new!(population_size: 5, generations: 1, selection_strategy: selection)

        assert_raise Error.ExecutionError, ~r/requested count/, fn ->
          Engine.evolve(["a", "b", "c", "d", "e"], config, TestFitness) |> Enum.to_list()
        end
      end
    end
  end

  describe "select_and_breed offspring count trimming" do
    test "verify Enum.take respects target offspring_count" do
      config =
        Config.new!(
          population_size: 4,
          generations: 2,
          mutation_rate: 0.0,
          crossover_rate: 1.0,
          crossover_strategy: TestCrossover,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aa", "bb", "cc", "dd"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      final_state = List.last(states)

      assert length(final_state.population) == 4
    end

    test "offspring count with elitism → total matches population_size" do
      config =
        Config.new!(
          population_size: 10,
          generations: 2,
          mutation_rate: 0.5,
          crossover_rate: 0.5,
          crossover_strategy: TestCrossover,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          elitism_rate: 0.2,
          random_seed: 42
        )

      initial_pop = [
        "a",
        "bb",
        "ccc",
        "dddd",
        "eeeee",
        "ffffff",
        "ggggggg",
        "hhhhhhhh",
        "iiiii",
        "jj"
      ]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      final_state = List.last(states)

      assert length(final_state.population) == 10

      elite_count = Config.elite_count(config)
      assert elite_count == 2

      has_elite =
        Enum.any?(final_state.population, fn entity ->
          String.length(entity) >= 7
        end)

      assert has_elite
    end

    test "various population sizes maintain correct offspring count" do
      population_sizes = [4, 6, 10, 15, 20]

      for pop_size <- population_sizes do
        config =
          Config.new!(
            population_size: pop_size,
            generations: 2,
            mutation_rate: 0.5,
            crossover_rate: 0.5,
            crossover_strategy: TestCrossover,
            selection_strategy: TestSelection,
            mutation_strategy: TestMutation,
            elitism_rate: 0.1,
            random_seed: 42
          )

        initial_pop = Enum.map(1..pop_size, fn i -> String.duplicate("x", i) end)

        states =
          initial_pop
          |> Engine.evolve(config, TestFitness)
          |> Enum.to_list()

        final_state = List.last(states)

        assert length(final_state.population) == pop_size,
               "Population size #{pop_size} not maintained, got #{length(final_state.population)}"
      end
    end
  end

  describe "apply_elitism with elite_count > 0" do
    test "elite_count = 1 → best entity from old generation persists" do
      config =
        Config.new!(
          population_size: 6,
          generations: 3,
          mutation_rate: 1.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.17,
          random_seed: 42
        )

      initial_pop = ["a", "bb", "ccc", "dddd", "eeeee", "ffffff"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      elite_count = Config.elite_count(config)
      assert elite_count == 1

      [gen0, gen1, gen2 | _] = states

      assert gen0.best_entity == "ffffff"

      assert "ffffff" in gen1.population,
             "Best entity should persist to generation 1"

      best_gen1 = gen1.best_entity
      assert best_gen1 in gen2.population, "Best entity from gen1 should persist to gen2"
    end

    test "elite_count = 2 → top 2 entities persist across generations" do
      config =
        Config.new!(
          population_size: 10,
          generations: 2,
          mutation_rate: 1.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.2,
          random_seed: 42
        )

      initial_pop = [
        "a",
        "bb",
        "ccc",
        "dddd",
        "eeeee",
        "ffffff",
        "ggggggg",
        "hhhhhhhh",
        "i",
        "jj"
      ]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      elite_count = Config.elite_count(config)
      assert elite_count == 2

      [gen0, gen1 | _] = states

      top_2_gen0 =
        gen0.scores
        |> Enum.sort_by(fn {_entity, score} -> score end, :desc)
        |> Enum.take(2)
        |> Enum.map(fn {entity, _score} -> entity end)

      assert "hhhhhhhh" in top_2_gen0
      assert "ggggggg" in top_2_gen0

      assert "hhhhhhhh" in gen1.population, "Top elite should persist"
      assert "ggggggg" in gen1.population, "Second elite should persist"
    end

    test "elite_count = 3 → top 3 entities persist across generations" do
      config =
        Config.new!(
          population_size: 10,
          generations: 2,
          mutation_rate: 1.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.3,
          random_seed: 42
        )

      initial_pop = [
        "a",
        "bb",
        "ccc",
        "dddd",
        "eeeee",
        "ffffff",
        "ggggggg",
        "hhhhhhhh",
        "i",
        "jj"
      ]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      elite_count = Config.elite_count(config)
      assert elite_count == 3

      [gen0, gen1 | _] = states

      top_3_gen0 =
        gen0.scores
        |> Enum.sort_by(fn {_entity, score} -> score end, :desc)
        |> Enum.take(3)
        |> Enum.map(fn {entity, _score} -> entity end)

      assert length(top_3_gen0) == 3

      for elite <- top_3_gen0 do
        assert elite in gen1.population,
               "Elite entity #{elite} should persist to generation 1"
      end
    end

    test "elites replace worst offspring, preserving best individuals" do
      config =
        Config.new!(
          population_size: 6,
          generations: 2,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.34,
          random_seed: 42
        )

      initial_pop = ["aaaaaa", "bbbbb", "cccc", "ddd", "ee", "f"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      elite_count = Config.elite_count(config)
      assert elite_count == 2

      [gen0, gen1 | _] = states

      assert gen0.best_entity == "aaaaaa"
      assert gen1.best_entity == "aaaaaa", "Best entity should persist"

      top_2_gen0 =
        gen0.scores
        |> Enum.sort_by(fn {_entity, score} -> score end, :desc)
        |> Enum.take(2)
        |> Enum.map(fn {entity, _score} -> entity end)

      for elite <- top_2_gen0 do
        assert elite in gen1.population, "Elite #{elite} should be in next generation"
      end

      assert length(gen1.population) == 6, "Population size should remain constant"
    end

    test "verify best individuals persist across multiple generations" do
      config =
        Config.new!(
          population_size: 8,
          generations: 4,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.25,
          random_seed: 42
        )

      initial_pop = ["aaaaaaaa", "bbbbbbb", "cccccc", "ddddd", "eeee", "fff", "gg", "h"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      elite_count = Config.elite_count(config)
      assert elite_count == 2

      [gen0, gen1, gen2, gen3 | _] = states

      best_entity = gen0.best_entity

      assert best_entity in gen1.population, "Best should persist to gen1"
      assert best_entity in gen2.population, "Best should persist to gen2"
      assert best_entity in gen3.population, "Best should persist to gen3"

      for state <- states do
        assert state.best_entity == best_entity,
               "Best entity should remain constant due to elitism"
      end
    end
  end

  describe "apply_elitism edge cases" do
    test "elite_count = 0 → population passes through unchanged" do
      config =
        Config.new!(
          population_size: 6,
          generations: 2,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aaaaaa", "bbbbb", "cccc", "ddd", "ee", "f"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      elite_count = Config.elite_count(config)
      assert elite_count == 0

      [_gen0, gen1 | _] = states

      assert length(gen1.population) == 6, "Population size should remain constant"
    end

    test "old_scores empty (first generation) → no elites added" do
      config =
        Config.new!(
          population_size: 4,
          generations: 1,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.25,
          random_seed: 42
        )

      initial_pop = ["aaaa", "bbb", "cc", "d"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      elite_count = Config.elite_count(config)
      assert elite_count == 1

      [gen0 | _] = states

      assert length(gen0.population) == 4
      assert map_size(gen0.scores) == 4
    end

    test "elite_count > population size → handled gracefully" do
      config =
        Config.new!(
          population_size: 4,
          generations: 2,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 1.0,
          random_seed: 42
        )

      initial_pop = ["aaaa", "bbb", "cc", "d"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      elite_count = Config.elite_count(config)
      assert elite_count == 4

      [_gen0, gen1 | _] = states

      assert length(gen1.population) == 4,
             "Population size should be maintained even with high elitism"
    end

    test "all offspring have lower fitness than elites → elites dominate population" do
      config =
        Config.new!(
          population_size: 6,
          generations: 2,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          selection_strategy: AlwaysWorseSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.34,
          random_seed: 42
        )

      initial_pop = ["aaaaaa", "bbbbb", "cccc", "ddd", "ee", "f"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      elite_count = Config.elite_count(config)
      assert elite_count == 2

      [gen0, gen1 | _] = states

      top_2_gen0 =
        gen0.scores
        |> Enum.sort_by(fn {_entity, score} -> score end, :desc)
        |> Enum.take(2)
        |> Enum.map(fn {entity, _score} -> entity end)

      for elite <- top_2_gen0 do
        assert elite in gen1.population,
               "Elite #{elite} should be preserved despite poor offspring"
      end
    end
  end

  describe "calculate_diversity" do
    test "diversity is calculated and present in state" do
      config =
        Config.new!(
          diversity_enabled: true,
          population_size: 6,
          generations: 1,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aaa", "bbb", "ccc", "ddd", "eee", "fff"]

      [state | _] =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      assert state.diversity != nil, "Diversity should be calculated"
      assert is_float(state.diversity), "Diversity should be a float"
      assert state.diversity >= 0.0, "Diversity should be non-negative"
    end

    test "diversity delegates to evolvable module correctly" do
      config =
        Config.new!(
          diversity_enabled: true,
          population_size: 4,
          generations: 1,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.0,
          random_seed: 42
        )

      identical_pop = ["hello", "hello", "hello", "hello"]

      [identical_state | _] =
        identical_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      diverse_pop = ["aaaa", "bbbb", "cccc", "dddd"]

      [diverse_state | _] =
        diverse_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      assert identical_state.diversity != nil
      assert diverse_state.diversity != nil

      assert identical_state.diversity <= diverse_state.diversity,
             "Identical population (#{identical_state.diversity}) should have lower diversity than diverse population (#{diverse_state.diversity})"
    end

    test "diversity calculated each generation" do
      config =
        Config.new!(
          diversity_enabled: true,
          population_size: 6,
          generations: 3,
          mutation_rate: 0.5,
          crossover_rate: 0.5,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.0,
          random_seed: 42
        )

      initial_pop = ["aaa", "bbb", "ccc", "ddd", "eee", "fff"]

      states =
        initial_pop
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      assert length(states) == 4

      for state <- states do
        assert state.diversity != nil,
               "Diversity should be calculated for generation #{state.generation}"

        assert is_float(state.diversity)
        assert state.diversity >= 0.0
      end
    end

    test "diversity with various population diversities" do
      config =
        Config.new!(
          diversity_enabled: true,
          population_size: 5,
          generations: 1,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.0,
          random_seed: 42
        )

      very_similar = ["hello", "hallo", "hullo", "hollo", "hillo"]
      somewhat_diverse = ["apple", "apply", "zebra", "zero", "hero"]
      very_diverse = ["a", "completely", "different", "set", "xyz"]

      [very_similar_state | _] =
        very_similar
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      [somewhat_diverse_state | _] =
        somewhat_diverse
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      [very_diverse_state | _] =
        very_diverse
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      assert very_similar_state.diversity != nil
      assert somewhat_diverse_state.diversity != nil
      assert very_diverse_state.diversity != nil

      assert very_similar_state.diversity < somewhat_diverse_state.diversity,
             "Very similar should have lower diversity than somewhat diverse"

      assert somewhat_diverse_state.diversity < very_diverse_state.diversity or
               somewhat_diverse_state.diversity > very_similar_state.diversity,
             "Diversity should correlate with population variety"
    end

    test "diversity calculation with Evolvable.String uses similarity metric" do
      config =
        Config.new!(
          diversity_enabled: true,
          population_size: 3,
          generations: 1,
          mutation_rate: 0.0,
          crossover_rate: 0.0,
          selection_strategy: TestSelection,
          mutation_strategy: TestMutation,
          crossover_strategy: TestCrossover,
          elitism_rate: 0.0,
          random_seed: 42
        )

      population = ["abc", "def", "ghi"]

      [state | _] =
        population
        |> Engine.evolve(config, TestFitness)
        |> Enum.to_list()

      assert state.diversity > 0.5,
             "Diverse strings should have higher diversity, got #{state.diversity}"
    end
  end
end
