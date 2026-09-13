defmodule Jido.Evolve.StateTest do
  use ExUnit.Case, async: true

  alias Jido.Evolve.{Config, State}

  test "new/1 validates config type" do
    assert {:error, errors} =
             State.new(%{
               population: ["a"],
               config: :invalid
             })

    assert Enum.any?(errors, fn
             %Zoi.Error{path: [:config]} -> true
             _ -> false
           end)
  end

  test "update_scores/2 sets best and average scores" do
    state = State.new(["a", "bb", "ccc"], Config.new!(diversity_enabled: true))
    updated = State.update_scores(state, %{"a" => 1.0, "bb" => 2.0, "ccc" => 3.0})

    assert updated.best_entity == "ccc"
    assert updated.best_score == 3.0
    assert_in_delta updated.average_score, 2.0, 1.0e-8
  end

  test "update_scores/2 handles empty score map" do
    state = State.new(["a", "b"], Config.new!(diversity_enabled: true))
    updated = State.update_scores(state, %{})

    assert updated.best_entity == nil
    assert updated.best_score == nil
    assert updated.average_score == 0.0
  end

  test "next_generation/2 advances generation and caps history at 100 entries" do
    state =
      State.new!(%{
        population: [1, 2, 3],
        config: Config.new!(diversity_enabled: true),
        generation: 5,
        scores: %{1 => 0.1},
        best_entity: 1,
        best_score: 0.75,
        average_score: 0.75,
        fitness_history: Enum.to_list(1..100)
      })

    next_state = State.next_generation(state, [4, 5, 6])

    assert next_state.population == [4, 5, 6]
    assert next_state.generation == 6
    assert next_state.scores == %{}
    assert next_state.best_entity == nil
    assert next_state.best_score == nil
    assert next_state.average_score == 0.0
    assert length(next_state.fitness_history) == 100
    assert hd(next_state.fitness_history) == 0.75
  end

  test "calculate_diversity/1 handles small and large populations" do
    singleton =
      State.new!(%{
        population: ["only"],
        config: Config.new!(diversity_enabled: true)
      })
      |> State.calculate_diversity()

    assert singleton.diversity == 0.0

    small =
      State.new!(%{
        population: ["abc", "abd", "xyz"],
        config: Config.new!(diversity_enabled: true)
      })
      |> State.calculate_diversity()

    assert small.diversity > 0.0
    assert small.diversity <= 1.0

    all_same_small =
      State.new!(%{
        population: ["same", "same"],
        config: Config.new!(diversity_enabled: true)
      })
      |> State.calculate_diversity()

    assert all_same_small.diversity == 0.0

    all_same_large =
      State.new!(%{
        population: Enum.map(1..10, fn _ -> "same" end),
        config: Config.new!(diversity_enabled: true)
      })
      |> State.calculate_diversity()

    assert all_same_large.diversity == 0.0
  end

  test "put_metadata/3 stores metadata entries" do
    state = State.new(["a"], Config.new!(diversity_enabled: true))
    updated = State.put_metadata(state, :source, :test)
    assert updated.metadata[:source] == :test
  end

  test "terminated?/1 handles max_generations and target_fitness criteria" do
    config = Config.new!(termination_criteria: [max_generations: 3, target_fitness: 0.9])

    at_generation_limit =
      State.new!(%{
        population: ["a"],
        config: config,
        generation: 3,
        best_score: 0.1
      })

    assert State.terminated?(at_generation_limit)

    at_target_fitness =
      State.new!(%{
        population: ["a"],
        config: config,
        generation: 0,
        best_score: 0.95
      })

    assert State.terminated?(at_target_fitness)
  end

  test "terminated?/1 handles no_improvement criteria" do
    config = Config.new!(termination_criteria: [no_improvement: 3])

    not_enough_history =
      State.new!(%{
        population: ["a"],
        config: config,
        fitness_history: [0.1, 0.1]
      })

    refute State.terminated?(not_enough_history)

    stable_history =
      State.new!(%{
        population: ["a"],
        config: config,
        fitness_history: [0.2, 0.2, 0.2],
        stagnant_generations: 3
      })

    assert State.terminated?(stable_history)
  end
end
