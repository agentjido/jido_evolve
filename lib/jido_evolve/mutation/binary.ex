defmodule Jido.Evolve.Mutation.Binary do
  @moduledoc """
  Bit-flip mutation for binary genomes.

  Randomly flips bits (0→1 or 1→0) based on mutation rate.
  Each position has an independent probability of being flipped.

  ## Usage

      config = %{
        mutation_strategy: Jido.Evolve.Mutation.Binary,
        mutation_rate: 0.1  # 10% chance per bit
      }
  """

  use Jido.Evolve.Mutation

  @genome_schema Zoi.list(Zoi.enum([0, 1]))
  @opts_schema Zoi.keyword(
                 [
                   rate: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(0.1)
                 ],
                 coerce: true
               )

  @impl true
  def mutate(genome, opts) do
    with {:ok, parsed_genome} <- parse_genome(genome),
         {:ok, parsed_opts} <- parse_opts(opts) do
      rate = Keyword.fetch!(parsed_opts, :rate)

      mutated_genome =
        Enum.map(parsed_genome, fn bit ->
          if :rand.uniform() < rate do
            1 - bit
          else
            bit
          end
        end)

      {:ok, mutated_genome}
    end
  end

  defp parse_genome(genome) do
    case Zoi.parse(@genome_schema, genome) do
      {:ok, parsed_genome} ->
        {:ok, parsed_genome}

      {:error, errors} ->
        {:error, "invalid binary genome: #{inspect(Zoi.treefy_errors(errors))}"}
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
        {:error, "invalid binary mutation opts: #{inspect(Zoi.treefy_errors(errors))}"}
    end
  end

  defp parse_opts(_opts), do: {:error, "invalid binary mutation opts: expected keyword list"}
end
