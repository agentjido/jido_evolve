defmodule Walkthrough.BitCount do
  @moduledoc "Count enabled bits. The known maximum is eight."
  use Jido.Evolve.Fitness

  @impl true
  @spec evaluate(list(integer()), map()) :: {:ok, integer()}
  def evaluate(bits, _context), do: {:ok, Enum.sum(bits)}
end

defmodule Walkthrough.ConfigurationScore do
  @moduledoc "A toy configuration objective with a known target. This is not a performance benchmark."
  use Jido.Evolve.Fitness

  @impl true
  @spec evaluate(map(), map()) :: {:ok, map()}
  def evaluate(candidate, %{target: target}) do
    error =
      10 * abs(candidate.workers - target.workers) +
        abs(candidate.batch_size - target.batch_size) +
        if(candidate.mode == target.mode, do: 0, else: 5)

    {:ok,
     %{
       score: error,
       metadata: %{worker_error: candidate.workers - target.workers},
       feedback: %{target_workers: target.workers}
     }}
  end
end

defmodule Walkthrough.FeedbackMutation do
  @moduledoc "Use evaluator feedback to correct the worker count."
  use Jido.Evolve.Mutation

  @impl true
  @spec mutate(map(), keyword()) :: {:ok, map()}
  def mutate(candidate, _opts), do: {:ok, candidate}

  @impl true
  @spec mutate_with_feedback(map(), map(), keyword()) :: {:ok, map()}
  def mutate_with_feedback(candidate, %{target_workers: workers}, _opts) do
    {:ok, %{candidate | workers: workers}}
  end
end

bits = [
  [1, 0, 1, 0, 1, 0, 1, 0],
  [0, 1, 0, 1, 0, 1, 0, 1],
  [1, 1, 0, 0, 1, 1, 0, 0],
  [0, 0, 1, 1, 0, 0, 1, 1],
  [1, 0, 0, 1, 1, 0, 0, 1],
  [0, 1, 1, 0, 0, 1, 1, 0]
]

bit_options = [
  initial_population: bits,
  fitness: Walkthrough.BitCount,
  mutation: Jido.Evolve.Mutation.Binary,
  crossover: Jido.Evolve.Crossover.Uniform,
  config: [
    generations: 50,
    mutation_rate: 0.1,
    crossover_rate: 0.8,
    elitism_rate: 0.2,
    max_evaluations: 306,
    random_seed: 42,
    termination_criteria: [target_fitness: 8]
  ]
]

states = Jido.Evolve.evolve(bit_options) |> Enum.to_list()

IO.inspect(Enum.map(states, &{&1.generation, &1.best_score, &1.evaluation_count}),
  label: "Bit search: generation, best score, attempts"
)

{:ok, bit_result} = Jido.Evolve.run(bit_options)

IO.inspect(Map.take(bit_result, [:best_entity, :best_score, :generation, :evaluation_count, :stop_reason]),
  label: "Bit result"
)

schema = %{
  workers: {:int, 1..12},
  batch_size: {:int, 8..64},
  mode: {:enum, [:fast, :balanced, :careful]}
}

configuration_options = [
  initial_population: [
    %{workers: 2, batch_size: 16, mode: :fast},
    %{workers: 4, batch_size: 32, mode: :careful},
    %{workers: 8, batch_size: 64, mode: :fast},
    %{workers: 10, batch_size: 48, mode: :careful},
    %{workers: 3, batch_size: 48, mode: :balanced},
    %{workers: 9, batch_size: 32, mode: :balanced}
  ],
  fitness: Walkthrough.ConfigurationScore,
  context: %{target: %{workers: 6, batch_size: 48, mode: :balanced}},
  mutation: Jido.Evolve.Mutation.HParams,
  mutation_opts: [schema: schema],
  crossover: Jido.Evolve.Crossover.MapUniform,
  config: [
    objective: :minimize,
    generations: 50,
    mutation_rate: 0.4,
    max_evaluations: 306,
    random_seed: 42,
    termination_criteria: [target_fitness: 0]
  ]
]

{:ok, configuration_result} = Jido.Evolve.run(configuration_options)

IO.inspect(Map.take(configuration_result, [:best_entity, :best_score, :generation, :evaluation_count, :stop_reason]),
  label: "Configuration result (toy objective)"
)

IO.inspect(configuration_result.best_evaluation.metadata, label: "Retained metadata")
IO.inspect(configuration_result.best_evaluation.feedback, label: "Retained feedback")

{:ok, feedback_result} =
  Jido.Evolve.run(
    initial_population: [%{workers: 2, batch_size: 48, mode: :balanced}],
    fitness: Walkthrough.ConfigurationScore,
    context: %{target: %{workers: 6, batch_size: 48, mode: :balanced}},
    mutation: Walkthrough.FeedbackMutation,
    crossover: Jido.Evolve.Crossover.MapUniform,
    config: [objective: :minimize, generations: 1, elitism_rate: 0.0, random_seed: 42]
  )

IO.inspect(Map.take(feedback_result, [:best_entity, :best_score, :evaluation_count]), label: "Feedback result")
