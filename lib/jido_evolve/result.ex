defmodule Jido.Evolve.Result do
  @moduledoc "The final result of a search, including partial work at cancellation or deadline."

  alias Jido.Evolve.{Evaluation, State}

  @enforce_keys [:stop_reason, :state]
  defstruct [
    :best_entity,
    :best_score,
    :best_evaluation,
    :population,
    :generation,
    :stop_reason,
    :state,
    evaluation_count: 0,
    failure_count: 0
  ]

  @type t :: %__MODULE__{
          best_entity: term(),
          best_score: number() | nil,
          best_evaluation: Evaluation.t() | nil,
          population: list() | nil,
          generation: non_neg_integer() | nil,
          evaluation_count: non_neg_integer(),
          failure_count: non_neg_integer(),
          stop_reason: atom(),
          state: State.t()
        }

  @doc "Create a result from the terminal state. Population and generation refer to the last complete generation."
  @spec from_state(State.t()) :: t()
  def from_state(state) do
    best = state.best_evaluation

    %__MODULE__{
      best_entity: if(best, do: best.entity),
      best_score: if(best, do: best.score),
      best_evaluation: best,
      population: state.last_complete_population,
      generation: state.last_complete_generation,
      evaluation_count: state.evaluation_count,
      failure_count: state.failure_count,
      stop_reason: state.stop_reason,
      state: state
    }
  end
end
