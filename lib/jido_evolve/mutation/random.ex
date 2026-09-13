defmodule Jido.Evolve.Mutation.Random do
  @moduledoc """
  Random mutation strategy for any evolvable entity.

  Applies random mutations to the genome representation of entities.
  """

  @behaviour Jido.Evolve.Mutation
  alias Jido.Evolve.Evolvable

  @opts_schema Zoi.keyword(
                 [
                   rate: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(0.1),
                   strength: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(1.0),
                   operations:
                     Zoi.list(Zoi.enum([:replace, :insert, :delete]))
                     |> Zoi.min(1)
                     |> Zoi.default([:replace, :insert, :delete])
                 ],
                 coerce: true
               )

  @doc """
  Apply random mutations to an entity.

  The mutation works on the genome representation and supports:
  - Character replacement (for strings/charlists)
  - Insertion of random elements
  - Deletion of elements

  ## Options

  - `:rate` - Mutation rate (0.0 to 1.0), default: 0.1
  - `:strength` - Multiplier on mutation probability (0.0 to 1.0), default: 1.0
  - `:operations` - List of allowed operations (default: [:replace, :insert, :delete])

  ## Examples

      iex> {:ok, mutated} = Jido.Evolve.Mutation.Random.mutate("hello", rate: 0.5)
      iex> is_binary(mutated)
      true
  """
  @impl true
  def mutate(entity, opts \\ []) do
    with {:ok, parsed_opts} <- parse_opts(opts) do
      rate = Keyword.fetch!(parsed_opts, :rate)
      strength = Keyword.fetch!(parsed_opts, :strength)
      operations = Keyword.fetch!(parsed_opts, :operations)

      genome = Evolvable.to_genome(entity)
      mutated_genome = apply_mutations(genome, rate * strength, operations)
      {:ok, Evolvable.from_genome(entity, mutated_genome)}
    end
  rescue
    error ->
      {:error, error}
  end

  # Private functions

  defp apply_mutations(genome, rate, operations) when is_list(genome) do
    genome
    |> Enum.with_index()
    |> Enum.reduce(genome, fn {_element, index}, acc ->
      if :rand.uniform() < rate do
        operation = Enum.random(operations)
        apply_mutation_operation(acc, operation, index)
      else
        acc
      end
    end)
    |> maybe_apply_insertions(rate, operations)
  end

  defp apply_mutation_operation(genome, :replace, index) when index < length(genome) do
    case Enum.at(genome, index) do
      char when is_integer(char) and char >= 32 and char <= 126 ->
        # Replace with random printable ASCII character
        new_char = Enum.random(32..126)
        List.replace_at(genome, index, new_char)

      _ ->
        genome
    end
  end

  defp apply_mutation_operation(genome, :delete, index)
       when index < length(genome) and length(genome) > 1 do
    List.delete_at(genome, index)
  end

  defp apply_mutation_operation(genome, :insert, index) when index <= length(genome) do
    # Insert random printable ASCII character
    new_char = Enum.random(32..126)
    List.insert_at(genome, index, new_char)
  end

  defp apply_mutation_operation(genome, _operation, _index), do: genome

  defp maybe_apply_insertions(genome, rate, operations) do
    if :insert in operations and :rand.uniform() < rate do
      # Random insertion at random position
      position = :rand.uniform(length(genome) + 1) - 1
      new_char = Enum.random(32..126)
      List.insert_at(genome, position, new_char)
    else
      genome
    end
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

  defp parse_opts(opts) when is_list(opts) do
    case Zoi.parse(@opts_schema, opts) do
      {:ok, parsed_opts} ->
        {:ok, parsed_opts}

      {:error, errors} ->
        {:error, "invalid random mutation opts: #{inspect(Zoi.treefy_errors(errors))}"}
    end
  end

  defp parse_opts(_opts), do: {:error, "invalid random mutation opts: expected keyword list"}
end
