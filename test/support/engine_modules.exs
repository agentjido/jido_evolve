defmodule TestEngine.CustomMutation do
  @moduledoc false
  @behaviour Jido.Evolve.Mutation

  @impl true
  def mutate(entity, _opts) when is_binary(entity), do: {:ok, entity <> "_custom"}

  @impl true
  def mutation_strength(_generation), do: 0.5
end

defmodule TestEngine.CustomSelection do
  @moduledoc false
  @behaviour Jido.Evolve.Selection

  @impl true
  def select(population, scores, count, opts) do
    population
    |> Enum.map(fn entity -> {entity, Map.get(scores, entity, 0.0)} end)
    |> Enum.sort_by(fn {entity, _score} -> String.length(Keyword.fetch!(opts, :evaluations)[entity].entity) end, :asc)
    |> Stream.cycle()
    |> Enum.take(count)
    |> Enum.map(fn {entity, _score} -> entity end)
  end
end

defmodule TestEngine.MetadataFitness do
  @moduledoc false
  @behaviour Jido.Evolve.Fitness

  @impl true
  def evaluate(entity, _context) do
    score = entity |> to_string() |> String.length() |> to_float()
    {:ok, %{score: score, metadata: "test"}}
  end

  @impl true
  def batch_evaluate(entities, context) do
    entities
    |> Enum.map(fn entity -> evaluate(entity, context) end)
    |> Enum.map(fn
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp to_float(int) when is_integer(int), do: int * 1.0
end

defmodule TestEngine.TimeoutFitness do
  @moduledoc false
  @behaviour Jido.Evolve.Fitness

  @impl true
  def evaluate(entity, _context) do
    if entity == "slow" do
      {:ok, 1.0}
    else
      {:ok, String.length(entity) * 1.0}
    end
  end

  @impl true
  def batch_evaluate(entities, context) do
    Enum.map(entities, &evaluate(&1, context))
  end
end

defmodule TestEngine.SlowFitness do
  @moduledoc false
  @behaviour Jido.Evolve.Fitness

  @impl true
  def evaluate(entity, %{delay: delay}) do
    Process.sleep(delay)
    {:ok, String.length(entity)}
  end

  @impl true
  def evaluate(entity, _context) do
    {:ok, String.length(entity)}
  end
end

defmodule TestEngine.MixedFitness do
  @moduledoc false
  @behaviour Jido.Evolve.Fitness

  @impl true
  def evaluate(entity, _context) do
    entity
    |> String.length()
    |> case do
      length when rem(length, 2) == 1 -> {:error, :odd_length}
      length -> {:ok, length * 1.0}
    end
  end

  @impl true
  def batch_evaluate(entities, context) do
    entities
    |> Enum.map(fn entity -> evaluate(entity, context) end)
    |> Enum.map(fn
      {:ok, score} -> {:ok, score}
      {:error, reason} -> {:error, reason}
    end)
  end
end

defmodule TestEngine.ErrorMutation do
  @moduledoc false
  @behaviour Jido.Evolve.Mutation

  @impl true
  def mutate(_entity, _opts), do: {:error, :deliberate_mutation_error}

  @impl true
  def mutation_strength(_generation), do: 0.5
end

defmodule TestEngine.OddSelection do
  @moduledoc false
  @behaviour Jido.Evolve.Selection

  @impl true
  def select(population, scores, count, _opts) do
    actual_count = if rem(count, 2) == 0, do: count - 1, else: count

    population
    |> Enum.map(fn entity -> {entity, Map.get(scores, entity, 0.0)} end)
    |> Enum.sort_by(fn {_entity, score} -> score end, :desc)
    |> Enum.take(actual_count)
    |> Enum.map(fn {entity, _score} -> entity end)
  end
end

defmodule TestEngine.OddSelection2 do
  @moduledoc false
  @behaviour Jido.Evolve.Selection

  @impl true
  def select(population, scores, count, _opts) do
    actual_count = if rem(count, 2) == 0, do: count - 1, else: count

    population
    |> Enum.map(fn entity -> {entity, Map.get(scores, entity, 0.0)} end)
    |> Enum.sort_by(fn {_entity, score} -> score end, :desc)
    |> Enum.take(actual_count)
    |> Enum.map(fn {entity, _score} -> entity end)
  end
end

defmodule TestEngine.AlwaysWorseSelection do
  @moduledoc false
  @behaviour Jido.Evolve.Selection

  @impl true
  def select(population, scores, count, _opts) do
    worst = Enum.min_by(population, &Map.fetch!(scores, &1))
    List.duplicate(worst, count)
  end
end
