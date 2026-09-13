defmodule Jido.Evolve.Evolvable.HParams do
  @moduledoc """
  Evolvable protocol implementation for hyperparameter maps.

  Supports schema-driven evolution of mixed-type parameters:
  - Floats with linear or log-scale bounds
  - Integers with min/max bounds
  - Enums (categorical choices)
  - Lists of values with length constraints

  ## Schema Format

  Bounds can be specified as either ranges (`min..max`) or tuples (`{min, max}`).
  Note: Ranges only work for integer bounds (Elixir requirement). Use tuples for float bounds.

      %{
        learning_rate: {:float, {1.0e-5, 1.0e-1}, :log},
        hidden_layers: {:list, {:int, 16..256}, length: {1, 3}},
        dropout_rate: {:float, {0.0, 0.6}, :linear},
        activation: {:enum, [:relu, :tanh, :gelu]},
        batch_size: {:enum, [16, 32, 64, 128]}
      }

  ## Usage

      schema = %{learning_rate: {:float, {0.001, 0.1}, :log}}
      hparams = Jido.Evolve.Evolvable.HParams.new(schema)
      # => %{learning_rate: 0.0032}
  """

  @doc """
  Creates a new random hyperparameter map from a schema.
  """
  @spec new(map()) :: map() | {:error, term()}
  def new(schema) when is_map(schema) do
    with {:ok, schema} <- normalize_schema(schema) do
      Enum.map(schema, fn {key, spec} ->
        {key, random_value(spec)}
      end)
      |> Map.new()
    end
  end

  def new(_), do: {:error, "HParams requires a schema map"}

  @doc "Validate a parameter schema and convert ranges to bounds."
  @spec normalize_schema(map()) :: {:ok, map()} | {:error, String.t()}
  def normalize_schema(schema) when is_map(schema) do
    {:ok, Map.new(schema, fn {key, spec} -> {key, normalize_spec(spec)} end)}
  rescue
    ArgumentError -> {:error, "invalid parameter schema"}
  end

  defp normalize_spec({:int, bounds}) do
    {low, high} = bounds!(bounds)
    if not is_integer(low) or not is_integer(high), do: raise(ArgumentError)
    {:int, {low, high}}
  end

  defp normalize_spec({:float, bounds, scale}) when scale in [:linear, :log] do
    {low, high} = bounds!(bounds)
    if scale == :log and low <= 0, do: raise(ArgumentError)
    {:float, {low, high}, scale}
  end

  defp normalize_spec({:enum, [_ | _] = choices}), do: {:enum, choices}

  defp normalize_spec({:list, spec, opts}) when is_list(opts) do
    if not Keyword.keyword?(opts), do: raise(ArgumentError)
    {low, high} = bounds!(Keyword.get(opts, :length, {1, 3}))
    if not is_integer(low) or not is_integer(high) or low < 0, do: raise(ArgumentError)
    {:list, normalize_spec(spec), [length: {low, high}]}
  end

  defp normalize_spec(_), do: raise(ArgumentError)
  defp bounds!(%Range{first: low, last: high, step: 1}), do: bounds!({low, high})
  defp bounds!({low, high}) when is_number(low) and is_number(high) and low <= high, do: {low, high}
  defp bounds!(_), do: raise(ArgumentError)

  defp normalize_bounds(min..max//_), do: {min, max}
  defp normalize_bounds({min, max}), do: {min, max}

  @doc "Create one value from a valid parameter specification."
  @spec random_value(tuple()) :: term()
  def random_value({:float, bounds, :linear}) do
    {min, max} = normalize_bounds(bounds)
    min + :rand.uniform() * (max - min)
  end

  def random_value({:float, bounds, :log}) do
    {min, max} = normalize_bounds(bounds)
    log_min = :math.log(min)
    log_max = :math.log(max)
    :math.exp(log_min + :rand.uniform() * (log_max - log_min))
  end

  def random_value({:int, bounds}) do
    {min, max} = normalize_bounds(bounds)
    min + :rand.uniform(max - min + 1) - 1
  end

  def random_value({:enum, choices}) when is_list(choices) do
    Enum.random(choices)
  end

  def random_value({:list, elem_spec, opts}) do
    length_range = Keyword.get(opts, :length, {1, 3})
    len = random_value({:int, length_range})
    List.duplicate(nil, len) |> Enum.map(fn _ -> random_value(elem_spec) end)
  end

  def random_value(_), do: nil

  defimpl Jido.Evolve.Evolvable, for: Map do
    @doc """
    Convert map to genome (identity operation).
    """
    def to_genome(map) when is_map(map) do
      map
    end

    @doc """
    Convert genome back to map (identity operation).
    """
    def from_genome(_original, genome) when is_map(genome) do
      genome
    end

    @doc """
    Calculate similarity between two hyperparameter maps.
    Returns 0.0 for identical, 1.0 for completely different.
    """
    def similarity(map1, map2) when is_map(map1) and is_map(map2) do
      keys = Map.keys(map1) |> MapSet.new()
      keys2 = Map.keys(map2) |> MapSet.new()

      if keys != keys2 do
        1.0
      else
        differences =
          Enum.count(keys, fn key ->
            Map.get(map1, key) != Map.get(map2, key)
          end)

        if map_size(map1) == 0, do: 0.0, else: differences / map_size(map1)
      end
    end

    @doc """
    Validates hyperparameters against basic type constraints.
    """
    def valid?(hparams) when is_map(hparams) do
      # Basic validation: all values are present and valid types
      Enum.all?(hparams, fn {_key, value} ->
        is_number(value) or is_atom(value) or is_list(value)
      end)
    end

    def valid?(_), do: false
  end
end
