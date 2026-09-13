defmodule Jido.Evolve.Config do
  @moduledoc """
  Canonical configuration structure for evolutionary algorithms.

  This module uses Zoi for validation and provides sensible defaults.
  """

  import Bitwise

  alias Jido.Evolve.Error

  @mutation_strategy_schema Zoi.atom() |> Zoi.refine({__MODULE__, :validate_mutation_strategy, []})
  @selection_strategy_schema Zoi.atom() |> Zoi.refine({__MODULE__, :validate_selection_strategy, []})
  @crossover_strategy_schema Zoi.atom() |> Zoi.refine({__MODULE__, :validate_crossover_strategy, []})

  @termination_criterion_schema Zoi.union([
                                  Zoi.tuple({Zoi.literal(:max_generations), Zoi.integer() |> Zoi.min(0)}),
                                  Zoi.tuple({Zoi.literal(:target_fitness), Zoi.number()}),
                                  Zoi.tuple({Zoi.literal(:no_improvement), Zoi.integer() |> Zoi.min(1)})
                                ])
  @termination_criteria_schema Zoi.list(@termination_criterion_schema)

  @schema Zoi.struct(
            __MODULE__,
            %{
              population_size: Zoi.integer() |> Zoi.min(1) |> Zoi.default(100),
              generations: Zoi.integer() |> Zoi.min(0) |> Zoi.default(1000),
              mutation_rate: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(0.1),
              crossover_rate: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(0.7),
              elitism_rate: Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.default(0.05),
              max_concurrency: Zoi.integer() |> Zoi.min(1) |> Zoi.default(System.schedulers_online()),
              selection_strategy: @selection_strategy_schema |> Zoi.default(Jido.Evolve.Selection.Tournament),
              mutation_strategy: @mutation_strategy_schema |> Zoi.default(Jido.Evolve.Mutation.Text),
              crossover_strategy: @crossover_strategy_schema |> Zoi.default(Jido.Evolve.Crossover.String),
              termination_criteria: @termination_criteria_schema |> Zoi.default([]),
              objective: Zoi.enum([:maximize, :minimize]) |> Zoi.default(:maximize),
              max_evaluations: Zoi.integer() |> Zoi.min(1) |> Zoi.nullish(),
              deadline_ms: Zoi.integer() |> Zoi.min(0) |> Zoi.nullish(),
              cleanup_timeout: Zoi.integer() |> Zoi.min(1) |> Zoi.default(1000),
              diversity_enabled: Zoi.boolean() |> Zoi.default(false),
              metrics_enabled: Zoi.boolean() |> Zoi.default(true),
              random_seed: Zoi.integer() |> Zoi.nullish(),
              tournament_size: Zoi.integer() |> Zoi.min(1) |> Zoi.default(2),
              evaluation_timeout:
                Zoi.union([
                  Zoi.integer() |> Zoi.min(1),
                  Zoi.literal(:infinity)
                ])
                |> Zoi.default(30_000)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Create a new configuration with validation.

  ## Examples

      iex> {:ok, config} = Jido.Evolve.Config.new(population_size: 50)
      iex> config.population_size
      50

      iex> {:error, _error} = Jido.Evolve.Config.new(population_size: -1)
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ [])

  def new(opts) when is_list(opts) or is_map(opts) do
    if is_map(opts) or Keyword.keyword?(opts) do
      opts_map = normalize_opts(opts)
      unknown = Map.keys(opts_map) -- Map.keys(Map.from_struct(struct(__MODULE__)))

      if unknown == [] do
        case Zoi.parse(@schema, opts_map) do
          {:ok, config} -> {:ok, config}
          {:error, errors} -> {:error, errors}
        end
      else
        {:error, Error.config_error("unknown configuration options", %{keys: unknown})}
      end
    else
      {:error, Error.config_error("config options must be a keyword list or map")}
    end
  end

  def new(_opts), do: {:error, Error.config_error("config options must be a keyword list or map")}

  @doc """
  Create a new configuration, raising on validation errors.

  ## Examples

      iex> config = Jido.Evolve.Config.new!(population_size: 50)
      iex> config.population_size
      50
  """
  @spec new!(keyword() | map()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, config} ->
        config

      {:error, error} ->
        if is_exception(error),
          do: raise(error),
          else: raise(Error.config_error("invalid configuration", %{errors: error}))
    end
  end

  @doc """
  Get the number of elite entities to preserve.
  """
  @spec elite_count(t()) :: non_neg_integer()
  def elite_count(%__MODULE__{population_size: pop_size, elitism_rate: rate}) do
    if rate > 0.0, do: max(1, round(pop_size * rate)), else: 0
  end

  @doc """
  Initialize random seed if configured.

  Uses explicit :exs1024 algorithm with deterministic seed tuple for reproducibility
  within the same OTP version.
  """
  @spec init_random_seed(t()) :: :ok
  def init_random_seed(%__MODULE__{random_seed: nil}), do: :ok

  @spec init_random_seed(t()) :: :ok
  def init_random_seed(%__MODULE__{random_seed: seed}) when is_integer(seed) do
    :rand.seed(:exs1024, {seed, seed <<< 1, seed <<< 2})
    :ok
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts

  @doc false
  @spec validate_mutation_strategy(module(), keyword()) :: :ok | {:error, String.t()}
  def validate_mutation_strategy(module, _opts) do
    validate_strategy_module(module, :mutate, 2, "mutation_strategy must export mutate/2")
  end

  @doc false
  @spec validate_selection_strategy(module(), keyword()) :: :ok | {:error, String.t()}
  def validate_selection_strategy(module, _opts) do
    validate_strategy_module(module, :select, 4, "selection_strategy must export select/4")
  end

  @doc false
  @spec validate_crossover_strategy(module(), keyword()) :: :ok | {:error, String.t()}
  def validate_crossover_strategy(module, _opts) do
    validate_strategy_module(module, :crossover, 3, "crossover_strategy must export crossover/3")
  end

  defp validate_strategy_module(module, function, arity, message) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      :ok
    else
      {:error, message}
    end
  end

  defp validate_strategy_module(_module, _function, _arity, message), do: {:error, message}
end
