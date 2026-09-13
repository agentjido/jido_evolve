defmodule Jido.Evolve.OptionsTest do
  use ExUnit.Case, async: true

  alias Jido.Evolve.{Config, Error, Options}

  alias TestOptions.{
    InvalidCrossoverModule,
    InvalidMutationModule,
    InvalidSelectionModule,
    MissingEvaluateFitness
  }

  test "new/1 validates and normalizes minimal required options" do
    assert {:ok, opts} =
             Options.new(
               initial_population: ["a", "bb", "ccc"],
               fitness: TestFitness
             )

    assert opts.initial_population == ["a", "bb", "ccc"]
    assert opts.fitness == TestFitness
    assert opts.context == %{}
    assert %Config{} = opts.config
    assert opts.mutation == opts.config.mutation_strategy
    assert opts.selection == opts.config.selection_strategy
    assert opts.crossover == opts.config.crossover_strategy
  end

  test "new/1 accepts config and strategy overrides" do
    config =
      Config.new!(
        population_size: 3,
        mutation_strategy: Jido.Evolve.Mutation.Text,
        selection_strategy: Jido.Evolve.Selection.Tournament,
        crossover_strategy: Jido.Evolve.Crossover.String
      )

    assert {:ok, opts} =
             Options.new(%{
               initial_population: ["a", "b", "c"],
               fitness: TestFitness,
               config: config,
               context: %{mode: :test},
               mutation: TestMutation,
               selection: TestSelection,
               crossover: TestCrossover
             })

    assert opts.config == config
    assert opts.context == %{mode: :test}
    assert opts.mutation == TestMutation
    assert opts.selection == TestSelection
    assert opts.crossover == TestCrossover
  end

  test "new/1 returns invalid input error for non keyword/map options" do
    assert {:error, %Error.InvalidInputError{message: message}} = Options.new("invalid")
    assert message =~ "keyword list or map"
  end

  test "new/1 returns invalid input error when required keys are missing" do
    assert {:error, %Error.InvalidInputError{message: "invalid evolve options"}} =
             Options.new(initial_population: ["a", "b"])
  end

  test "new/1 returns invalid input error for empty population" do
    assert {:error, %Error.InvalidInputError{field: :initial_population, message: message}} =
             Options.new(initial_population: [], fitness: TestFitness)

    assert message =~ "must not be empty"
  end

  test "new/1 returns invalid input error when fitness is not an atom module" do
    assert {:error, %Error.InvalidInputError{field: :fitness, message: "fitness must be a module"}} =
             Options.new(initial_population: ["a"], fitness: "not_a_module")
  end

  test "new/1 returns invalid input error when fitness module is missing evaluate/2" do
    assert {:error, %Error.InvalidInputError{field: :fitness, message: message}} =
             Options.new(initial_population: ["a"], fitness: MissingEvaluateFitness)

    assert message =~ "evaluate/2"
  end

  test "new/1 returns config error for invalid config type" do
    assert {:error, %Error.ConfigError{message: message}} =
             Options.new(initial_population: ["a"], fitness: TestFitness, config: 123)

    assert message =~ "config must be nil, map, keyword list"
  end

  test "new/1 returns config error for invalid config values" do
    assert {:error, %Error.ConfigError{message: "invalid config for evolve/1"}} =
             Options.new(
               initial_population: ["a"],
               fitness: TestFitness,
               config: [evaluation_timeout: 0]
             )
  end

  test "new/1 returns invalid input errors for invalid strategy modules" do
    assert {:error, %Error.InvalidInputError{field: :mutation}} =
             Options.new(
               initial_population: ["a"],
               fitness: TestFitness,
               mutation: InvalidMutationModule
             )

    assert {:error, %Error.InvalidInputError{field: :selection}} =
             Options.new(
               initial_population: ["a"],
               fitness: TestFitness,
               selection: InvalidSelectionModule
             )

    assert {:error, %Error.InvalidInputError{field: :crossover}} =
             Options.new(
               initial_population: ["a"],
               fitness: TestFitness,
               crossover: InvalidCrossoverModule
             )
  end

  test "new!/1 raises when options are invalid" do
    assert_raise Error.InvalidInputError, fn ->
      Options.new!(initial_population: [], fitness: TestFitness)
    end
  end
end
