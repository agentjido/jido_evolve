defmodule Jido.Evolve.Random do
  @moduledoc false

  @doc false
  @spec seed(integer() | nil) :: :rand.state()
  def seed(nil), do: :rand.seed_s(:exs1024)
  def seed(seed), do: :rand.seed_s(:exs1024, {seed, seed * 2, seed * 4})

  @doc false
  @spec with_state(:rand.state(), (-> term())) :: {term(), :rand.state()}
  def with_state(state, fun) do
    previous = Process.get(:rand_seed)

    try do
      :rand.seed(state)
      value = fun.()
      {value, Process.get(:rand_seed)}
    after
      if previous, do: Process.put(:rand_seed, previous), else: Process.delete(:rand_seed)
    end
  end
end
