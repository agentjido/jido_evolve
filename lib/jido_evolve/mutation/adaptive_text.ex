defmodule Jido.Evolve.Mutation.AdaptiveText do
  @moduledoc """
  Adaptive text mutation strategy that adjusts mutation rate based on fitness.

  Uses high mutation rate early for exploration, then lowers it as fitness
  improves for fine-tuning convergence.
  """

  @behaviour Jido.Evolve.Mutation
  alias Jido.Evolve.Mutation.Text

  @opts_schema Zoi.keyword(
                 [
                   rate: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(0.3),
                   strength: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(1.0),
                   high_rate: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.nullish(),
                   low_rate: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(0.08),
                   fitness_threshold: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(0.75),
                   best_fitness: Zoi.number() |> Zoi.default(0.0),
                   operations: Zoi.list(Zoi.enum([:replace, :insert, :delete])) |> Zoi.min(1) |> Zoi.default([:replace])
                 ],
                 coerce: true
               )

  @doc """
  Apply adaptive mutation to a string entity.

  ## Options

  - `:rate` - Base mutation rate (adjusted based on fitness context)
  - `:strength` - Multiplier on mutation probability (0.0 to 1.0), default: 1.0
  - `:operations` - List of allowed operations (default: [:replace])
  - `:high_rate` - High mutation rate for early exploration (default: :rate)
  - `:low_rate` - Low mutation rate for convergence (default: 0.08)
  - `:fitness_threshold` - Switch to low rate when best fitness exceeds this (default: 0.75)
  - `:best_fitness` - Current best fitness (from context, required for adaptation)
  """
  @impl true
  def mutate(entity, opts \\ [])

  def mutate(entity, opts) when is_binary(entity) do
    with {:ok, parsed_opts} <- parse_opts(opts) do
      high_rate = Keyword.get(parsed_opts, :high_rate) || Keyword.fetch!(parsed_opts, :rate)
      low_rate = min(Keyword.fetch!(parsed_opts, :low_rate), high_rate)
      fitness_threshold = Keyword.fetch!(parsed_opts, :fitness_threshold)
      best_fitness = Keyword.fetch!(parsed_opts, :best_fitness)
      operations = Keyword.fetch!(parsed_opts, :operations)

      adaptive_rate = if best_fitness >= fitness_threshold, do: low_rate, else: high_rate

      Text.mutate(entity,
        rate: adaptive_rate,
        strength: Keyword.fetch!(parsed_opts, :strength),
        operations: operations
      )
    end
  end

  def mutate(entity, _opts) do
    {:error, "Adaptive text mutation only works with string entities, got: #{inspect(entity)}"}
  end

  @doc """
  Calculate mutation strength based on generation number.
  """
  @impl true
  def mutation_strength(generation) do
    max(0.1, 1.0 - generation / 1000.0)
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
        {:error, "invalid adaptive text mutation opts: #{inspect(Zoi.treefy_errors(errors))}"}
    end
  end

  defp parse_opts(_opts), do: {:error, "invalid adaptive text mutation opts: expected keyword list"}
end
