defmodule Jido.Evolve.Mutation.Permutation do
  @moduledoc """
  Mutation strategies for permutation genomes.

  Supports three mutation modes:
  - `:swap` - Swap two random positions
  - `:inversion` - Reverse a random segment
  - `:insertion` - Remove an element and insert it elsewhere

  ## Options

  - `:mode` - Mutation mode (default: `:swap`)
  - `:rate` - Mutation rate (default: from config)

  ## Examples

      # Swap mutation
      mutate([0, 1, 2, 3, 4], 1.0, mode: :swap)
      # => [0, 3, 2, 1, 4]

      # Inversion mutation
      mutate([0, 1, 2, 3, 4], 1.0, mode: :inversion)
      # => [0, 3, 2, 1, 4]

      # Insertion mutation
      mutate([0, 1, 2, 3, 4], 1.0, mode: :insertion)
      # => [0, 1, 3, 4, 2]
  """

  use Jido.Evolve.Mutation

  @opts_schema Zoi.keyword(
                 [
                   mode:
                     Zoi.enum([
                       :swap,
                       :inversion,
                       :insertion
                     ])
                     |> Zoi.default(:swap),
                   rate: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(0.1)
                 ],
                 coerce: true
               )

  @impl true
  def mutate(permutation, opts) when is_list(permutation) do
    with {:ok, parsed_opts} <- parse_opts(opts) do
      rate = Keyword.fetch!(parsed_opts, :rate)
      mode = Keyword.fetch!(parsed_opts, :mode)

      if :rand.uniform() < rate do
        case mode do
          :swap -> swap(permutation)
          :inversion -> inversion(permutation)
          :insertion -> insertion(permutation)
        end
      else
        {:ok, permutation}
      end
    end
  end

  def mutate(_genome, _opts) do
    {:error, "Permutation mutation requires list genome"}
  end

  @impl true
  @doc "Validate mutation options before a run starts."
  @spec validate_opts(keyword()) :: :ok | {:error, term()}
  def validate_opts(opts) do
    case parse_opts(opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_opts(opts) when is_map(opts), do: parse_opts(Map.to_list(opts))

  defp parse_opts(opts) when is_list(opts) do
    case Zoi.parse(@opts_schema, opts) do
      {:ok, parsed_opts} ->
        {:ok, parsed_opts}

      {:error, errors} ->
        {:error, "invalid permutation mutation opts: #{inspect(Zoi.treefy_errors(errors))}"}
    end
  end

  defp parse_opts(_opts), do: {:error, "invalid permutation mutation opts: expected keyword list or map"}

  # Swap two random positions
  defp swap(permutation) do
    n = length(permutation)

    if n < 2 do
      {:ok, permutation}
    else
      i = :rand.uniform(n) - 1
      j = :rand.uniform(n) - 1

      if i == j do
        {:ok, permutation}
      else
        list = List.replace_at(permutation, i, Enum.at(permutation, j))
        list = List.replace_at(list, j, Enum.at(permutation, i))
        {:ok, list}
      end
    end
  end

  # Reverse a random segment
  defp inversion(permutation) do
    n = length(permutation)

    if n < 2 do
      {:ok, permutation}
    else
      i = :rand.uniform(n) - 1
      j = :rand.uniform(n) - 1
      {start_idx, end_idx} = if i <= j, do: {i, j}, else: {j, i}

      if start_idx == end_idx do
        {:ok, permutation}
      else
        before = Enum.slice(permutation, 0, start_idx)
        segment = Enum.slice(permutation, start_idx, end_idx - start_idx + 1) |> Enum.reverse()
        after_segment = Enum.slice(permutation, end_idx + 1, n - end_idx - 1)

        {:ok, before ++ segment ++ after_segment}
      end
    end
  end

  # Remove an element and insert it elsewhere
  defp insertion(permutation) do
    n = length(permutation)

    if n < 2 do
      {:ok, permutation}
    else
      from_idx = :rand.uniform(n) - 1
      to_idx = :rand.uniform(n) - 1

      if from_idx == to_idx do
        {:ok, permutation}
      else
        value = Enum.at(permutation, from_idx)
        without = List.delete_at(permutation, from_idx)
        result = List.insert_at(without, to_idx, value)
        {:ok, result}
      end
    end
  end
end
