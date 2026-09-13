defmodule Jido.Evolve do
  @moduledoc """
  Jido.Evolve is a generic evolutionary algorithm framework for Elixir.

  Use `run/1` for a final result and `evolve/1` for a lazy stream of states.
  """

  alias Jido.Evolve.{Engine, Error, Options, Result}

  @doc """
  Run an evolutionary search over a population.

  ## Required options

  - `:initial_population` - List of entities to evolve.
  - `:fitness` - Module implementing `evaluate/2`.

  ## Optional options

  - `:config` - `%Jido.Evolve.Config{}` or config options map/keyword.
  - `:context` - Context map passed to `fitness.evaluate/2`.
  - `:mutation` - Mutation strategy module override.
  - `:selection` - Selection strategy module override.
  - `:crossover` - Crossover strategy module override.
  - `:mutation_opts`, `:selection_opts`, `:crossover_opts` - Explicit operator settings.
  - `:cancellation` - Optional `Jido.Evolve.Cancellation` token.

  Generation 0 evaluates the initial population. Configured generations count
  breeding transitions. The stream includes the terminal state. Diversity is
  optional and disabled by default. See the getting started guide for budgets,
  failures, callback contracts, and partial terminal states.

  ## Examples

      defmodule MyFitness do
        use Jido.Evolve.Fitness

        def evaluate(entity, _ctx), do: {:ok, String.length(entity)}
      end

      Jido.Evolve.evolve(
        initial_population: ["a", "abc", "ab"],
        fitness: MyFitness
      )
      |> Enum.to_list()
  """
  @spec evolve(keyword() | map()) :: Enumerable.t()
  def evolve(opts) when is_list(opts) or is_map(opts) do
    normalized = Options.new!(opts)

    Engine.stream(normalized)
  end

  def evolve(_opts) do
    raise Error.validation_error("evolve/1 expects a keyword list or map")
  end

  @doc """
  Consume a search and return its best result and work counts.

  Returns `{:error, error}` for invalid options, operator errors, or a run without
  any valid evaluation. For a run failure, `error.details.result` contains the
  final result. Deadline and cancellation return `{:ok, result}` when a valid
  evaluation has completed.
  """
  @spec run(keyword() | map()) :: {:ok, Result.t()} | {:error, Exception.t()}
  def run(opts) do
    with {:ok, normalized} <- Options.new(opts) do
      result = normalized |> Engine.stream() |> Enum.reduce(nil, fn state, _ -> state end) |> Result.from_state()

      if result.best_evaluation == nil do
        {:error, Error.execution_error("search completed without a valid evaluation", %{result: result})}
      else
        {:ok, result}
      end
    end
  rescue
    error in [Error.ExecutionError, Error.InvalidInputError, Error.ConfigError] -> {:error, error}
    error -> {:error, Error.execution_error("search callback failed", %{cause: error})}
  catch
    kind, reason -> {:error, Error.execution_error("search callback failed", %{kind: kind, reason: reason})}
  end

  @doc """
  Get version information.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:jido_evolve, :vsn) |> List.to_string()
  end
end
