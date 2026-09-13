defmodule Jido.Evolve.Mutation.HParamsTest do
  use ExUnit.Case, async: true

  alias Jido.Evolve.Mutation.HParams

  test "returns validation error without schema" do
    assert {:error, message} = HParams.mutate(%{lr: 0.01}, rate: 1.0)
    assert message =~ "invalid hparams mutation opts"
  end

  test "returns error for non-map genome" do
    assert {:error, "HParams mutation requires map genome"} = HParams.mutate("not a map", schema: %{})
  end

  test "returns error for invalid options shape" do
    assert {:error, message} = HParams.mutate(%{lr: 0.01}, %{schema: %{}, rate: -0.1})
    assert message =~ "invalid hparams mutation opts"
  end

  test "mutates scalar parameter types while preserving bounds" do
    schema = %{
      learning_rate: {:float, {0.001, 0.1}, :linear},
      log_lr: {:float, {1.0e-5, 1.0e-1}, :log},
      batch_size: {:int, {16, 128}},
      activation: {:enum, [:relu, :tanh, :gelu]}
    }

    input = %{
      learning_rate: 0.01,
      log_lr: 0.001,
      batch_size: 64,
      activation: :relu,
      passthrough: :keep_me
    }

    :rand.seed(:exsplus, {101, 102, 103})
    assert {:ok, mutated} = HParams.mutate(input, schema: schema, rate: 1.0, gaussian_scale: 0.3)

    assert mutated.learning_rate >= 0.001
    assert mutated.learning_rate <= 0.1
    assert mutated.log_lr >= 9.9e-6
    assert mutated.log_lr <= 1.0e-1
    assert mutated.batch_size >= 16
    assert mutated.batch_size <= 128
    assert mutated.activation in [:relu, :tanh, :gelu]
    assert mutated.passthrough == :keep_me
  end

  test "covers list mutation insert, delete, and in-place mutation paths" do
    schema = %{layers: {:list, {:int, {16, 64}}, length: {1, 4}}}
    input = %{layers: [32, 48]}

    outcomes =
      for seed <- 1..150 do
        :rand.seed(:exsplus, {seed, seed + 1, seed + 2})
        {:ok, mutated} = HParams.mutate(input, schema: schema, rate: 1.0)
        {length(mutated.layers), mutated.layers}
      end

    assert Enum.any?(outcomes, fn {len, _} -> len < 2 end)
    assert Enum.any?(outcomes, fn {len, _} -> len > 2 end)
    assert Enum.any?(outcomes, fn {len, layers} -> len == 2 and layers != [32, 48] end)
  end

  test "does not mutate values when rate is zero" do
    schema = %{learning_rate: {:float, {0.001, 0.1}, :linear}}
    input = %{learning_rate: 0.05}

    assert {:ok, ^input} = HParams.mutate(input, schema: schema, rate: 0.0)
  end
end
