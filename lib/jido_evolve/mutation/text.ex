defmodule Jido.Evolve.Mutation.Text do
  @moduledoc """
  Text-specific mutation strategy that works directly with strings.

  This mutation strategy is designed specifically for text/string evolution
  and provides efficient mutations for string data.
  """

  @behaviour Jido.Evolve.Mutation

  @alphabet String.to_charlist("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ ,!?")
  @opts_schema Zoi.keyword(
                 [
                   rate: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(0.1),
                   strength: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(1.0),
                   operations: Zoi.list(Zoi.enum([:replace, :insert, :delete])) |> Zoi.min(1) |> Zoi.default([:replace])
                 ],
                 coerce: true
               )

  @doc """
  Apply random mutations to a string entity.

  ## Options

  - `:rate` - Mutation rate (0.0 to 1.0), default: 0.1
  - `:strength` - Multiplier on mutation probability (0.0 to 1.0), default: 1.0
  - `:operations` - List of allowed operations (default: [:replace])

  ## Examples

      iex> {:ok, mutated} = Jido.Evolve.Mutation.Text.mutate("hello", rate: 0.5)
      iex> is_binary(mutated)
      true
  """
  @impl true
  def mutate(entity, opts \\ [])

  def mutate(entity, opts) when is_binary(entity) do
    with {:ok, parsed_opts} <- parse_opts(opts) do
      rate = Keyword.fetch!(parsed_opts, :rate) * Keyword.fetch!(parsed_opts, :strength)
      operations = Keyword.fetch!(parsed_opts, :operations)

      chars = String.to_charlist(entity)
      mutated_chars = apply_mutations(chars, rate, operations)
      {:ok, List.to_string(mutated_chars)}
    end
  end

  # Handle non-string entities
  def mutate(entity, _opts) do
    {:error, "Text mutation only works with string entities, got: #{inspect(entity)}"}
  end

  @doc """
  Calculate mutation strength based on generation number.
  Returns a value between 0.0 and 1.0.
  """
  @impl true
  def mutation_strength(generation) do
    # Start with high mutation strength, decrease over time
    max(0.1, 1.0 - generation / 1000.0)
  end

  # Private functions

  defp apply_mutations(chars, rate, operations) when is_list(chars) do
    chars
    |> Enum.with_index()
    |> Enum.reduce(chars, fn {_char, index}, acc ->
      if :rand.uniform() < rate do
        operation = Enum.random(operations)
        apply_mutation_operation(acc, operation, index)
      else
        acc
      end
    end)
    |> maybe_apply_insertions(rate, operations)
  end

  defp apply_mutation_operation(chars, :replace, index) when index < length(chars) do
    case Enum.at(chars, index) do
      char when is_integer(char) ->
        # Replace with random character from alphabet
        new_char = Enum.random(@alphabet)
        List.replace_at(chars, index, new_char)

      _ ->
        chars
    end
  end

  defp apply_mutation_operation(chars, :delete, index)
       when index < length(chars) and length(chars) > 1 do
    List.delete_at(chars, index)
  end

  defp apply_mutation_operation(chars, :insert, index) when index <= length(chars) do
    # Insert random printable ASCII character
    new_char = Enum.random(32..126)
    List.insert_at(chars, index, new_char)
  end

  defp apply_mutation_operation(chars, _operation, _index), do: chars

  defp maybe_apply_insertions(chars, rate, operations) do
    if :insert in operations and :rand.uniform() < rate do
      # Random insertion at random position
      position = :rand.uniform(length(chars) + 1) - 1
      new_char = Enum.random(32..126)
      List.insert_at(chars, position, new_char)
    else
      chars
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
        {:error, "invalid text mutation opts: #{inspect(Zoi.treefy_errors(errors))}"}
    end
  end

  defp parse_opts(_opts), do: {:error, "invalid text mutation opts: expected keyword list"}
end
