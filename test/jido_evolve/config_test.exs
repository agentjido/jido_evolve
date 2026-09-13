defmodule Jido.Evolve.ConfigTest do
  use ExUnit.Case
  doctest Jido.Evolve.Config

  alias TestOptions.{InvalidCrossoverModule, InvalidMutationModule, InvalidSelectionModule}

  test "creates config with defaults" do
    {:ok, config} = Jido.Evolve.Config.new()

    assert config.population_size == 100
    assert config.generations == 1000
    assert config.mutation_rate == 0.1
    assert config.crossover_rate == 0.7
    assert config.elitism_rate == 0.05
  end

  test "creates config with custom values" do
    {:ok, config} = Jido.Evolve.Config.new(population_size: 50, mutation_rate: 0.2)

    assert config.population_size == 50
    assert config.mutation_rate == 0.2
    # Default preserved
    assert config.generations == 1000
  end

  test "validates config parameters" do
    assert {:error, _} = Jido.Evolve.Config.new(population_size: -1)
    assert {:error, _} = Jido.Evolve.Config.new(mutation_rate: 1.5)
  end

  test "validates evaluation timeout and termination criteria" do
    assert {:error, timeout_errors} = Jido.Evolve.Config.new(evaluation_timeout: 0)

    assert Enum.any?(timeout_errors, fn
             %Zoi.Error{path: [:evaluation_timeout]} -> true
             _ -> false
           end)

    assert {:ok, _config} = Jido.Evolve.Config.new(evaluation_timeout: :infinity)

    assert {:error, criteria_errors} =
             Jido.Evolve.Config.new(termination_criteria: %{max_generations: 10})

    assert Enum.any?(criteria_errors, fn
             %Zoi.Error{path: [:termination_criteria]} -> true
             _ -> false
           end)

    assert {:ok, _config} =
             Jido.Evolve.Config.new(termination_criteria: [max_generations: 10, target_fitness: 0.9])

    assert {:error, invalid_criteria_errors} =
             Jido.Evolve.Config.new(termination_criteria: [unknown: :value])

    assert Enum.any?(invalid_criteria_errors, fn
             %Zoi.Error{path: [:termination_criteria | _]} -> true
             _ -> false
           end)
  end

  test "validates strategy modules implement required callbacks" do
    assert {:error, mutation_errors} = Jido.Evolve.Config.new(mutation_strategy: InvalidMutationModule)

    assert Enum.any?(mutation_errors, fn
             %Zoi.Error{path: [:mutation_strategy]} -> true
             _ -> false
           end)

    assert {:error, selection_errors} = Jido.Evolve.Config.new(selection_strategy: InvalidSelectionModule)

    assert Enum.any?(selection_errors, fn
             %Zoi.Error{path: [:selection_strategy]} -> true
             _ -> false
           end)

    assert {:error, crossover_errors} = Jido.Evolve.Config.new(crossover_strategy: InvalidCrossoverModule)

    assert Enum.any?(crossover_errors, fn
             %Zoi.Error{path: [:crossover_strategy]} -> true
             _ -> false
           end)
  end

  test "rejects non keyword/map config input" do
    assert {:error, %Jido.Evolve.Error.ConfigError{message: "config options must be a keyword list or map"}} =
             Jido.Evolve.Config.new(:invalid)
  end

  test "calculates elite count correctly" do
    {:ok, config} = Jido.Evolve.Config.new(population_size: 100, elitism_rate: 0.1)
    assert Jido.Evolve.Config.elite_count(config) == 10

    {:ok, config} = Jido.Evolve.Config.new(population_size: 50, elitism_rate: 0.02)
    # Minimum of 1
    assert Jido.Evolve.Config.elite_count(config) == 1
  end

  test "init_random_seed handles nil and integer seeds" do
    assert :ok = Jido.Evolve.Config.init_random_seed(Jido.Evolve.Config.new!())
    assert :ok = Jido.Evolve.Config.init_random_seed(Jido.Evolve.Config.new!(random_seed: 123))
  end
end
