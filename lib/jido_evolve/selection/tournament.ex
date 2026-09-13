defmodule Jido.Evolve.Selection.Tournament do
  @moduledoc "Tournament selection. Scores are utilities: larger values win."

  use Jido.Evolve.Selection

  @doc "Select `count` members with replacement. Unscored members are excluded."
  @spec select(list(), map(), non_neg_integer(), keyword()) :: list()
  @impl true
  def select(population, scores, count, opts \\ [])

  def select(population, scores, count, opts) when is_list(opts) do
    size = Keyword.get(opts, :tournament_size, 2)
    valid = Enum.filter(population, &is_number(Map.get(scores, &1)))

    if count <= 0 or valid == [] or validate_opts(opts) != :ok do
      []
    else
      Enum.map(1..count, fn _ ->
        valid |> Enum.take_random(min(size, length(valid))) |> Enum.max_by(&Map.fetch!(scores, &1))
      end)
    end
  end

  def select(_population, _scores, _count, _opts), do: []

  @impl true
  @doc "Validate tournament size. Selection pressure was removed; use tournament size."
  @spec validate_opts(keyword()) :: :ok | {:error, String.t()}
  def validate_opts(opts) do
    size = Keyword.get(opts, :tournament_size, 2)

    cond do
      Keyword.has_key?(opts, :pressure) -> {:error, "pressure is not supported; use tournament_size"}
      not is_integer(size) or size < 1 -> {:error, "tournament_size must be positive"}
      true -> :ok
    end
  end
end
