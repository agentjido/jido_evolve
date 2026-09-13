defmodule Jido.Evolve.Selection do
  @moduledoc """
  Behaviour for selection strategies.

  Selection determines which entities from the current population
  should be chosen as parents for the next generation.
  """

  @type entity :: {non_neg_integer(), non_neg_integer()}
  @type population :: list(entity())
  @type scores :: %{entity() => number()}
  @type count :: non_neg_integer()
  @type opts :: keyword()

  @doc "Validate strategy options before evaluation starts."
  @callback validate_opts(keyword()) :: :ok | {:error, term()}
  @optional_callbacks validate_opts: 1

  @doc """
  Select entities from the population for reproduction.

  ## Parameters

  - `population` - IDs of valid evaluated members
  - `scores` - Map of member ID to utility; higher is always better
  - `count` - Number of entities to select
  - `opts` - Strategy options and `:evaluations`, a map from ID to evaluation record

  ## Returns

  Exactly `count` valid member IDs, with replacement when needed.

  ## Examples

      def select(population, scores, count, opts) do
        # Tournament selection implementation
        Enum.take_random(population, count)
      end
  """
  @callback select(population(), scores(), count(), opts()) :: population()

  @doc """
  Maintain diversity in the selected population.

  This optional callback can be implemented to ensure
  the selected population maintains genetic diversity.
  """
  @callback maintain_diversity(population(), population(), opts()) :: population()

  @optional_callbacks [maintain_diversity: 3]

  defmacro __using__(_opts) do
    quote do
      @behaviour Jido.Evolve.Selection

      @doc """
      Default diversity maintenance that returns the selected population unchanged.
      """
      def maintain_diversity(_population, selected, _opts) do
        selected
      end

      defoverridable maintain_diversity: 3
    end
  end
end
