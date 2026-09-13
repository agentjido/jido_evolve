defmodule Jido.EvolveTest do
  use ExUnit.Case
  doctest Jido.Evolve

  test "returns package version" do
    assert Jido.Evolve.version() =~ ~r/^\d+\.\d+\.\d+/
  end

  test "evolve/1 raises for invalid option type" do
    assert_raise Jido.Evolve.Error.InvalidInputError, fn ->
      Jido.Evolve.evolve(:invalid)
    end
  end

  test "evolve/1 returns a stream for minimal valid options" do
    stream =
      Jido.Evolve.evolve(
        initial_population: ["a", "bb", "ccc"],
        fitness: TestFitness
      )

    assert is_function(stream, 2)
    assert [%Jido.Evolve.State{} | _] = Enum.take(stream, 1)
  end
end
