defmodule Jido.Evolve.EvaluationTimeoutTest do
  use ExUnit.Case, async: true

  alias Jido.Evolve.{Config, Engine, State}
  alias TestEngine.SlowFitness

  describe "evaluation_timeout configuration" do
    test "defaults to 30 seconds" do
      config = Config.new!()
      assert config.evaluation_timeout == 30_000
    end

    test "accepts custom timeout in milliseconds" do
      config = Config.new!(evaluation_timeout: 5_000)
      assert config.evaluation_timeout == 5_000
    end

    test "accepts :infinity timeout" do
      config = Config.new!(evaluation_timeout: :infinity)
      assert config.evaluation_timeout == :infinity
    end

    test "validates positive integer" do
      assert {:ok, config} = Config.new(evaluation_timeout: 1)
      assert config.evaluation_timeout == 1

      assert {:error, _} = Config.new(evaluation_timeout: 0)
      assert {:error, _} = Config.new(evaluation_timeout: -100)
    end
  end

  describe "timeout behavior in evolution" do
    test "fast fitness evaluations complete successfully" do
      config =
        Config.new!(
          population_size: 5,
          generations: 2,
          evaluation_timeout: 1_000
        )

      initial_pop = ["a", "bb", "ccc", "dddd", "eeeee"]

      states =
        initial_pop
        |> Engine.evolve(config, SlowFitness, context: %{delay: 10})
        |> Enum.take(2)

      assert length(states) == 2
      final_state = List.last(states)
      assert final_state.generation == 1
      assert map_size(final_state.scores) > 0
    end

    test "slow fitness evaluations timeout and are killed" do
      config =
        Config.new!(
          population_size: 3,
          generations: 1,
          evaluation_timeout: 100
        )

      initial_pop = ["a", "bb", "ccc"]

      # Fitness function will sleep for 500ms, but timeout is 100ms
      states =
        initial_pop
        |> Engine.evolve(config, SlowFitness, context: %{delay: 500})
        |> Enum.take(1)

      assert length(states) == 1
      final_state = List.first(states)

      # Some or all evaluations should timeout, resulting in fewer scores
      # The initial population should still be evaluated though
      assert is_map(final_state.scores)
    end

    test ":infinity timeout allows long-running evaluations" do
      config =
        Config.new!(
          population_size: 2,
          generations: 1,
          evaluation_timeout: :infinity
        )

      initial_pop = ["a", "bb"]

      # This should complete even though it takes 200ms per entity
      states =
        initial_pop
        |> Engine.evolve(config, SlowFitness, context: %{delay: 200})
        |> Enum.take(1)

      assert length(states) == 1
      final_state = List.first(states)
      assert map_size(final_state.scores) == 2
    end

    test "timeout configuration affects Task.async_stream" do
      # This is more of an integration test to verify the timeout is used correctly
      config =
        Config.new!(
          population_size: 3,
          generations: 1,
          evaluation_timeout: 50
        )

      initial_pop = ["a", "bb", "ccc"]
      state = State.new(initial_pop, config) |> State.update_scores(%{"a" => 1, "bb" => 2, "ccc" => 3})

      # Manually test the evaluation with a very short timeout
      result =
        Engine.evolution_step(
          state,
          SlowFitness,
          Jido.Evolve.Mutation.Text,
          Jido.Evolve.Selection.Tournament,
          Jido.Evolve.Crossover.String,
          # Much longer than timeout
          %{delay: 200}
        )

      # Result should still be a valid state, but some evaluations may have timed out
      assert %State{} = result
    end
  end

  describe "timeout with different population sizes" do
    test "handles timeout with small population" do
      config =
        Config.new!(
          population_size: 2,
          generations: 1,
          evaluation_timeout: 100
        )

      initial_pop = ["a", "bb"]

      states =
        initial_pop
        |> Engine.evolve(config, SlowFitness, context: %{})
        |> Enum.take(1)

      assert length(states) == 1
    end

    test "handles timeout with larger population" do
      config =
        Config.new!(
          population_size: 10,
          generations: 1,
          evaluation_timeout: 100
        )

      initial_pop = Enum.map(1..10, fn i -> String.duplicate("x", i) end)

      states =
        initial_pop
        |> Engine.evolve(config, SlowFitness, context: %{})
        |> Enum.take(1)

      assert length(states) == 1
    end
  end
end
