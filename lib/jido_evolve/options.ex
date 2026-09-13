defmodule Jido.Evolve.Options do
  @moduledoc """
  Canonical option validation and normalization for `Jido.Evolve.evolve/1`.
  """

  alias Jido.Evolve.{Cancellation, Config, Error}

  @population_schema Zoi.list(Zoi.any()) |> Zoi.refine({__MODULE__, :validate_population, []})
  @fitness_schema Zoi.any() |> Zoi.refine({__MODULE__, :validate_fitness, []})
  @mutation_override_schema Zoi.any() |> Zoi.nullish() |> Zoi.refine({__MODULE__, :validate_mutation_override, []})
  @selection_override_schema Zoi.any() |> Zoi.nullish() |> Zoi.refine({__MODULE__, :validate_selection_override, []})
  @crossover_override_schema Zoi.any() |> Zoi.nullish() |> Zoi.refine({__MODULE__, :validate_crossover_override, []})

  @schema Zoi.struct(
            __MODULE__,
            %{
              initial_population: @population_schema,
              fitness: @fitness_schema,
              config: Zoi.any() |> Zoi.nullish(),
              context: Zoi.map() |> Zoi.default(%{}),
              mutation: @mutation_override_schema,
              selection: @selection_override_schema,
              crossover: @crossover_override_schema,
              mutation_opts: Zoi.any() |> Zoi.default([]),
              selection_opts: Zoi.any() |> Zoi.default([]),
              crossover_opts: Zoi.any() |> Zoi.default([]),
              cancellation: Zoi.any() |> Zoi.nullish()
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
  Validate and normalize public evolve options.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Exception.t()}
  def new(opts) when is_list(opts) or is_map(opts) do
    with :ok <- validate_shape(opts),
         opts_map = normalize_opts(opts),
         :ok <- reject_unknown(opts_map),
         {:ok, parsed} <- parse(opts_map),
         {:ok, config} <- normalize_config(parsed.config, length(parsed.initial_population)),
         {:ok, mutation} <- resolve_strategy(parsed.mutation || config.mutation_strategy, :mutation),
         {:ok, selection} <- resolve_strategy(parsed.selection || config.selection_strategy, :selection),
         {:ok, crossover} <- resolve_strategy(parsed.crossover || config.crossover_strategy, :crossover),
         :ok <- validate_options(mutation, parsed.mutation_opts),
         :ok <- validate_options(selection, parsed.selection_opts),
         :ok <- validate_options(crossover, parsed.crossover_opts),
         :ok <- validate_cancellation(parsed.cancellation),
         :ok <- validate_budget(config, length(parsed.initial_population)) do
      {:ok,
       %{
         parsed
         | config: config,
           mutation: mutation,
           selection: selection,
           crossover: crossover
       }}
    end
  end

  def new(_opts) do
    {:error, Error.validation_error("evolve/1 options must be a keyword list or map")}
  end

  @doc """
  Validate and normalize options, raising on invalid input.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, normalized} ->
        normalized

      {:error, error} ->
        raise error
    end
  end

  defp validate_shape(opts) do
    if is_map(opts) or Keyword.keyword?(opts),
      do: :ok,
      else: {:error, Error.validation_error("options must be a keyword list or map")}
  end

  defp reject_unknown(opts) do
    unknown = Map.keys(opts) -- Map.keys(Map.from_struct(struct(__MODULE__)))
    if unknown == [], do: :ok, else: {:error, Error.validation_error("unknown evolve options", %{keys: unknown})}
  end

  defp validate_options(module, opts) do
    cond do
      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:error, Error.validation_error("strategy options must be a keyword list", %{module: module})}

      function_exported?(module, :validate_opts, 1) ->
        case module.validate_opts(opts) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, Error.validation_error("invalid strategy options", %{module: module, reason: reason})}
        end

      true ->
        :ok
    end
  end

  defp validate_cancellation(nil), do: :ok
  defp validate_cancellation(%Cancellation{}), do: :ok
  defp validate_cancellation(_), do: {:error, Error.validation_error("cancellation must be a Cancellation token")}

  defp validate_budget(config, size) do
    cond do
      config.population_size != size ->
        {:error, Error.config_error("population_size must match initial_population")}

      config.max_evaluations != nil and config.max_evaluations < size ->
        {:error, Error.config_error("max_evaluations must cover the initial population")}

      true ->
        :ok
    end
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts

  defp parse(opts_map) do
    case Zoi.parse(@schema, opts_map) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, errors} ->
        {:error, zoi_validation_error(errors)}
    end
  end

  @doc false
  @spec validate_population(list(any()), keyword()) :: :ok | {:error, String.t()}
  def validate_population(population, _opts) when is_list(population) do
    if Enum.empty?(population) do
      {:error, "initial_population must not be empty"}
    else
      :ok
    end
  end

  @doc false
  @spec validate_fitness(any(), keyword()) :: :ok | {:error, String.t()}
  def validate_fitness(module, _opts) do
    cond do
      not is_atom(module) ->
        {:error, "fitness must be a module"}

      not module_exports?(module, :evaluate, 2) ->
        {:error, "fitness module must export evaluate/2"}

      true ->
        :ok
    end
  end

  defp normalize_config(nil, size), do: Config.new(population_size: size)
  defp normalize_config(%Config{} = config, size), do: normalize_config(Map.from_struct(config), size)

  defp normalize_config(config_opts, size) when is_list(config_opts) or is_map(config_opts) do
    opts = if is_list(config_opts) and Keyword.keyword?(config_opts), do: Map.new(config_opts), else: config_opts
    opts = if is_map(opts), do: Map.put_new(opts, :population_size, size), else: opts

    case Config.new(opts) do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        {:error, Error.config_error("invalid config for evolve/1", %{details: reason})}
    end
  end

  defp normalize_config(other, _size) do
    {:error, Error.config_error("config must be nil, map, keyword list, or %Jido.Evolve.Config{}", %{value: other})}
  end

  defp resolve_strategy(module, :mutation) do
    if match?(:ok, validate_mutation_override(module, [])) do
      {:ok, module}
    else
      {:error, Error.validation_error("mutation strategy must export mutate/2", %{field: :mutation, value: module})}
    end
  end

  defp resolve_strategy(module, :selection) do
    if match?(:ok, validate_selection_override(module, [])) do
      {:ok, module}
    else
      {:error, Error.validation_error("selection strategy must export select/4", %{field: :selection, value: module})}
    end
  end

  defp resolve_strategy(module, :crossover) do
    if match?(:ok, validate_crossover_override(module, [])) do
      {:ok, module}
    else
      {:error,
       Error.validation_error("crossover strategy must export crossover/3", %{field: :crossover, value: module})}
    end
  end

  @doc false
  @spec validate_mutation_override(any(), keyword()) :: :ok | {:error, String.t()}
  def validate_mutation_override(nil, _opts), do: :ok

  def validate_mutation_override(module, _opts) do
    if module_exports?(module, :mutate, 2) do
      :ok
    else
      {:error, "mutation strategy must export mutate/2"}
    end
  end

  @doc false
  @spec validate_selection_override(any(), keyword()) :: :ok | {:error, String.t()}
  def validate_selection_override(nil, _opts), do: :ok

  def validate_selection_override(module, _opts) do
    if module_exports?(module, :select, 4) do
      :ok
    else
      {:error, "selection strategy must export select/4"}
    end
  end

  @doc false
  @spec validate_crossover_override(any(), keyword()) :: :ok | {:error, String.t()}
  def validate_crossover_override(nil, _opts), do: :ok

  def validate_crossover_override(module, _opts) do
    if module_exports?(module, :crossover, 3) do
      :ok
    else
      {:error, "crossover strategy must export crossover/3"}
    end
  end

  defp module_exports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp module_exports?(_module, _function, _arity), do: false

  defp zoi_validation_error([first_error | _] = errors) do
    field = List.first(first_error.path)

    message =
      if first_error.code == :custom do
        first_error.message
      else
        "invalid evolve options"
      end

    Error.validation_error(message, %{field: field, details: Zoi.treefy_errors(errors)})
  end

  defp zoi_validation_error(_errors), do: Error.validation_error("invalid evolve options")
end
