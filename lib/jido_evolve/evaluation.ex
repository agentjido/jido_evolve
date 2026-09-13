defmodule Jido.Evolve.Evaluation do
  @moduledoc "An evaluation of one population member. Equal values retain separate IDs."

  @enforce_keys [:id, :entity]
  defstruct [:id, :entity, :score, :feedback, :error, status: :error, metadata: %{}, data: %{}]

  @type t :: %__MODULE__{
          id: {non_neg_integer(), non_neg_integer()},
          entity: term(),
          status: :ok | :invalid | :error | :cancelled,
          score: number() | nil,
          metadata: term(),
          feedback: term(),
          error: term(),
          data: map()
        }

  @doc "Build a record from a fitness callback result."
  @spec new(tuple(), term(), term()) :: t()
  def new(id, entity, {:ok, score}) when is_number(score) do
    %__MODULE__{id: id, entity: entity, status: :ok, score: score}
  end

  def new(id, entity, {:ok, %{score: score} = data}) when is_number(score) do
    %__MODULE__{
      id: id,
      entity: entity,
      status: :ok,
      score: score,
      metadata: Map.get(data, :metadata, %{}),
      feedback: Map.get(data, :feedback),
      data: data
    }
  end

  def new(id, entity, {:invalid, reason}), do: failure(id, entity, :invalid, reason)
  def new(id, entity, {:error, reason}), do: failure(id, entity, :error, reason)
  def new(id, entity, other), do: failure(id, entity, :error, {:invalid_result, other})

  @doc "Build a record for an invalid, failed, or cancelled evaluation."
  @spec failure(tuple(), term(), :invalid | :error | :cancelled, term()) :: t()
  def failure(id, entity, status, reason) do
    %__MODULE__{id: id, entity: entity, status: status, error: reason}
  end
end
