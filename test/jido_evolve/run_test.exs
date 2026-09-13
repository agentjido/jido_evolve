defmodule Jido.Evolve.RunTest do
  use ExUnit.Case, async: true

  alias Jido.Evolve
  alias Jido.Evolve.{Cancellation, Config, Error, Evolvable, Result}

  defmodule Fitness do
    @moduledoc false
    def evaluate(entity, %{evaluate: fun}), do: fun.(entity)
    def evaluate(entity, _context) when is_number(entity), do: {:ok, entity}
    def evaluate(entity, _context) when is_list(entity), do: {:ok, Enum.sum(entity)}
    def evaluate(entity, _context) when is_binary(entity), do: {:ok, String.length(entity)}
  end

  defmodule Mutation do
    @moduledoc false
    def mutate(entity, opts), do: {:ok, Keyword.get(opts, :transform, &Function.identity/1).(entity)}
    def mutate_with_feedback(_entity, %{next: value}, _opts), do: {:ok, value}
  end

  defmodule Crossover do
    @moduledoc false
    def crossover(a, b, opts) do
      if Map.has_key?(opts, :observer), do: send(opts.observer, {:crossed, a, b})
      {a, b}
    end
  end

  defmodule BadSelection do
    @moduledoc false
    def select(_population, _scores, _count, _opts), do: [:unknown]
  end

  defmodule InvalidMutation do
    @moduledoc false
    def mutate(_entity, _opts), do: :invalid
  end

  defp options(population, config, extra \\ []) do
    Keyword.merge(
      [
        initial_population: population,
        fitness: Fitness,
        mutation: Mutation,
        crossover: Crossover,
        config: Keyword.merge([generations: 1, random_seed: 42], config)
      ],
      extra
    )
  end

  test "a lazy stream does no evaluation until consumption and has no lookahead" do
    test = self()

    opts =
      options([1, 2, 3], [],
        context: %{
          evaluate: fn x ->
            send(test, :evaluated)
            {:ok, x}
          end
        }
      )

    stream = Evolve.evolve(opts)
    refute_received :evaluated
    assert [state] = Enum.take(stream, 1)
    assert state.generation == 0
    for _ <- 1..3, do: assert_received(:evaluated)
    refute_received :evaluated
  end

  test "generation zero and each breeding transition are returned" do
    assert Enum.map(Evolve.evolve(options([1, 2], generations: 2)), & &1.generation) == [0, 1, 2]

    assert {:ok, %Result{generation: 0, evaluation_count: 2, stop_reason: :generations}} =
             Evolve.run(options([1, 2], generations: 0))
  end

  test "initial and newly reached fitness targets are returned" do
    assert [state] = Evolve.evolve(options([3], termination_criteria: [target_fitness: 3])) |> Enum.to_list()
    assert state.best_score == 3

    opts =
      options([1], [generations: 10, elitism_rate: 0.0, termination_criteria: [target_fitness: 2]],
        mutation_opts: [transform: &(&1 + 1)]
      )

    assert [initial, final] = Evolve.evolve(opts) |> Enum.to_list()
    assert initial.best_score == 1
    assert final.best_score == 2
    assert final.stop_reason == :termination_criterion
  end

  test "best seen result survives a later worse generation" do
    opts = options([10], [elitism_rate: 0.0], mutation_opts: [transform: &(&1 - 1)])
    assert {:ok, result} = Evolve.run(opts)
    assert result.best_score == 10
    assert result.state.best_score == 9
    assert result.population == [9]
    assert result.best_evaluation.id == {0, 0}
  end

  test "minimize controls selection, elitism, result, and target" do
    opts = options([8, 1, 4], objective: :minimize, tournament_size: 3, elitism_rate: 0.34)
    assert {:ok, result} = Evolve.run(opts)
    assert result.population == [1, 1, 1]
    assert result.best_score == 1
    opts = options([8, 1, 4], objective: :minimize, termination_criteria: [target_fitness: 1])
    assert {:ok, %{generation: 0, best_score: 1}} = Evolve.run(opts)
  end

  test "duplicates retain distinct evaluations and fill all elite positions" do
    opts = options(List.duplicate("a", 10), elitism_rate: 0.5, diversity_enabled: true)
    assert [initial, final] = Evolve.evolve(opts) |> Enum.to_list()
    assert length(final.population) == 10
    assert length(Enum.uniq_by(initial.evaluations, & &1.id)) == 10
    assert final.evaluation_count == 20
    assert final.diversity == 0.0
  end

  test "duplicate values with different evaluations remain distinct in selection" do
    counter = :atomics.new(1, [])

    opts =
      options([:same, :same], [max_concurrency: 1, elitism_rate: 0.0, tournament_size: 2],
        context: %{
          evaluate: fn _ ->
            score = :atomics.add_get(counter, 1, 1)
            {:ok, %{score: score, feedback: %{next: score}}}
          end
        }
      )

    assert {:ok, result} = Evolve.run(opts)
    assert result.population == [2, 2]
  end

  test "average score counts members rather than unique values" do
    assert {:ok, result} = Evolve.run(options([1, 1, 4], generations: 0))
    assert result.state.average_score == 2.0
  end

  test "invalid candidates, errors, crashes, throws, and bad returns cannot beat negative scores" do
    evaluate = fn
      :invalid -> {:invalid, :out_of_bounds}
      :error -> {:error, :failed}
      :crash -> raise "failed"
      :throw -> throw(:failed)
      :bad -> :wrong
      :exit -> exit(:failed)
      value -> {:ok, value}
    end

    opts = options([:invalid, :error, :crash, :throw, :bad, :exit, -4], [], context: %{evaluate: evaluate})
    assert {:ok, result} = Evolve.run(opts)
    assert result.best_score == -4
    assert result.population == List.duplicate(-4, 7)
    assert result.failure_count == 6
    assert result.evaluation_count == 14
  end

  test "all failed evaluations return explicit failure, with counts and records" do
    opts =
      options([1, 2], [termination_criteria: [target_fitness: -10]],
        context: %{evaluate: fn _ -> {:error, :failed} end}
      )

    assert {:error, %Error.ExecutionError{details: %{result: result}}} = Evolve.run(opts)
    assert result.stop_reason == :no_valid_candidates
    assert result.best_score == nil
    assert result.evaluation_count == 2
    assert result.failure_count == 2
  end

  test "retained feedback drives mutation without a model" do
    opts =
      options([1], [elitism_rate: 0.0],
        context: %{
          evaluate: fn x ->
            {:ok, %{score: x, metadata: %{case: :fixed}, feedback: %{next: x + 1}, trace: [:step]}}
          end
        }
      )

    assert {:ok, result} = Evolve.run(opts)
    assert result.best_entity == 2
    assert result.best_evaluation.metadata == %{case: :fixed}
    assert result.best_evaluation.feedback == %{next: 3}
    assert result.best_evaluation.data.trace == [:step]
  end

  test "only retained offspring are mutated, including an odd population" do
    observer = self()

    opts =
      options([1, 2, 3, 4, 5], [elitism_rate: 0.0, crossover_rate: 1.0],
        mutation_opts: [
          transform: fn x ->
            send(observer, :mutated)
            x
          end
        ],
        crossover_opts: [observer: observer]
      )

    assert {:ok, _} = Evolve.run(opts)
    for _ <- 1..5, do: assert_received(:mutated)
    refute_received :mutated
    for _ <- 1..3, do: assert_received({:crossed, _, _})
    refute_received {:crossed, _, _}
  end

  test "evaluation limits count failures and stop before a full next generation" do
    opts =
      options([1, 2, 3], [generations: 100, max_evaluations: 7],
        context: %{
          evaluate: fn
            1 -> {:error, :failed}
            x -> {:ok, x}
          end
        }
      )

    assert {:ok, result} = Evolve.run(opts)
    assert result.evaluation_count == 6
    assert result.failure_count == 1
    assert result.generation == 1
    assert result.stop_reason == :max_evaluations
  end

  test "rejects invalid options and too small budgets before evaluation" do
    observer = self()

    base =
      options([1, 2], [],
        context: %{
          evaluate: fn _ ->
            send(observer, :evaluated)
            {:ok, 1}
          end
        }
      )

    for config <- [
          [max_evaluations: 1],
          [population_size: 3],
          [generations: -1],
          [checkpoint_interval: 1],
          [selection_pressure: 1.0]
        ] do
      assert {:error, _} = Evolve.run(Keyword.put(base, :config, config))
    end

    for extra <- [[mutation_module: Mutation], [mutation_opts: :invalid], [cancellation: :invalid]] do
      assert {:error, _} = Evolve.run(Keyword.merge(base, extra))
    end

    assert {:error, _} = Evolve.run([:invalid])
    assert {:error, _} = Evolve.run(initial_population: [], fitness: Fitness)
    assert_raise Error.ConfigError, fn -> Config.new!(generations: -1) end
    refute_received :evaluated
  end

  test "seeds are independent across streams, processes, and caller random state" do
    opts =
      options(List.duplicate([0, 0, 0, 0], 4), [generations: 4, mutation_rate: 0.5],
        mutation: Jido.Evolve.Mutation.Binary,
        crossover: Jido.Evolve.Crossover.Uniform
      )

    a = Evolve.evolve(opts)
    b = Evolve.evolve(opts)
    :rand.seed(:exsplus, {11, 12, 13})
    before = :rand.export_seed()
    result_a = Enum.to_list(a)
    assert :rand.export_seed() == before
    :rand.uniform()
    result_b = Task.async(fn -> Enum.to_list(b) end) |> Task.await()
    assert result_a == result_b
    assert Enum.to_list(Evolve.evolve(opts)) == result_a
  end

  test "stagnation includes the latest score, works for window one and over 100 generations" do
    assert {:ok, %{generation: 1}} =
             Evolve.run(options([1], generations: 200, termination_criteria: [no_improvement: 1]))

    assert {:ok, %{generation: 105}} =
             Evolve.run(options([1], generations: 200, termination_criteria: [no_improvement: 105]))

    opts =
      options([1], [generations: 4, elitism_rate: 0.0, termination_criteria: [no_improvement: 1]],
        mutation_opts: [transform: &(&1 + 0.00001)]
      )

    assert {:ok, %{generation: 4, stop_reason: :generations}} = Evolve.run(opts)
  end

  test "custom values require no Evolvable protocol when diversity is off" do
    opts = options([{:policy, 1}, {:policy, 2}], [], context: %{evaluate: fn {:policy, x} -> {:ok, x} end})
    assert {:ok, result} = Evolve.run(opts)
    assert result.best_entity == {:policy, 2}
    assert result.state.diversity == nil
  end

  test "empty supported values have defined distance" do
    assert Evolvable.similarity([], []) == 0.0
    assert Evolvable.similarity(%{}, %{}) == 0.0

    for population <- [List.duplicate([], 10), List.duplicate("", 10)] do
      assert {:ok, %{state: %{diversity: +0.0}}} =
               Evolve.run(options(population, generations: 0, diversity_enabled: true))
    end
  end

  test "known optimum binary fixture reaches all ones" do
    opts =
      options(List.duplicate([0, 0, 0, 0], 4), [mutation_rate: 1.0, elitism_rate: 0.0],
        mutation: Jido.Evolve.Mutation.Binary,
        crossover: Jido.Evolve.Crossover.Uniform
      )

    assert {:ok, %{best_entity: [1, 1, 1, 1], best_score: 4}} = Evolve.run(opts)
  end

  test "permutation fixture preserves the set through variation" do
    opts =
      options([[1, 2, 3, 4], [4, 3, 2, 1]], [generations: 10, mutation_rate: 1.0, crossover_rate: 1.0],
        mutation: Jido.Evolve.Mutation.Permutation,
        crossover: Jido.Evolve.Crossover.PMX,
        mutation_opts: [mode: :inversion]
      )

    for state <- Evolve.evolve(opts), candidate <- state.population do
      assert Enum.sort(candidate) == [1, 2, 3, 4]
    end
  end

  test "structured configuration fixture passes schema options and stays bounded" do
    schema = %{width: {:int, 1..3}, layers: {:list, {:int, 2..5}, length: {0, 2}}}

    opts =
      options(
        [%{width: 1, layers: []}, %{width: 3, layers: [2]}],
        [generations: 10, mutation_rate: 1.0, crossover_rate: 1.0],
        mutation: Jido.Evolve.Mutation.HParams,
        crossover: Jido.Evolve.Crossover.MapUniform,
        mutation_opts: [schema: schema],
        context: %{evaluate: fn x -> {:ok, -abs(x.width - 2)} end}
      )

    for state <- Evolve.evolve(opts), candidate <- state.population do
      assert candidate.width in 1..3
      assert length(candidate.layers) in 0..2
      assert Enum.all?(candidate.layers, &(&1 in 2..5))
    end

    assert {:error, _} = Evolve.run(Keyword.delete(opts, :mutation_opts))
    assert {:error, _} = Evolve.run(Keyword.put(opts, :mutation_opts, schema: %{width: {:enum, []}}))
    assert %{layers: []} = Jido.Evolve.Evolvable.HParams.new(%{layers: {:list, {:int, 1..2}, length: {0, 0}}})
  end

  test "malformed operator results report an execution error" do
    assert {:error, %Error.ExecutionError{}} = Evolve.run(options([1, 2], [], selection: BadSelection))

    assert {:error, %Error.ExecutionError{}} =
             Evolve.run(options([1, 2], [elitism_rate: 0.0], mutation: InvalidMutation))
  end

  test "cancellation before consumption schedules no evaluations" do
    token = Cancellation.new()
    :ok = Cancellation.cancel(token)
    assert {:error, %{details: %{result: result}}} = Evolve.run(options([1], [], cancellation: token))
    assert result.evaluation_count == 0
    assert result.stop_reason == :cancelled
    assert result.population == nil
  end

  test "cancellation stops running evaluations and does not schedule queued work" do
    token = Cancellation.new()
    observer = self()

    evaluate = fn
      :fast ->
        {:ok, 1}

      x ->
        send(observer, {:started, x, self()})

        receive do
          :finish -> {:ok, 2}
        end
    end

    task =
      Task.async(fn ->
        Evolve.run(
          options([:fast, :slow, :queued], [max_concurrency: 1, evaluation_timeout: :infinity],
            context: %{evaluate: evaluate},
            cancellation: token
          )
        )
      end)

    assert_receive {:started, :slow, worker}, 1000
    monitor = Process.monitor(worker)
    Cancellation.cancel(token)
    assert {:ok, result} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert result.best_entity == :fast
    assert result.population == nil
    assert result.evaluation_count == 2
    assert result.stop_reason == :cancelled
    refute_received {:started, :queued, _}
  end

  test "deadline returns completed best and last complete population" do
    observer = self()
    counter = :atomics.new(1, [])

    evaluate = fn x ->
      if :atomics.add_get(counter, 1, 1) > 2 do
        send(observer, {:worker, self()})

        receive do
          :finish -> {:ok, x}
        end
      else
        {:ok, x}
      end
    end

    assert {:ok, result} =
             Evolve.run(
               options([1, 2], [deadline_ms: 100, evaluation_timeout: :infinity], context: %{evaluate: evaluate})
             )

    assert result.population == [1, 2]
    assert result.generation == 0
    assert result.stop_reason == :deadline
    assert result.best_score == 2
    assert_received {:worker, a}
    assert_received {:worker, b}
    refute Process.alive?(a)
    refute Process.alive?(b)
  end

  test "evaluation timeouts kill tasks and preserve valid negative scores" do
    observer = self()

    evaluate = fn
      :slow ->
        send(observer, {:worker, self()})

        receive do
          :finish -> {:ok, 10}
        end

      x ->
        {:ok, x}
    end

    assert {:ok, result} =
             Evolve.run(options([:slow, -10], [generations: 0, evaluation_timeout: 20], context: %{evaluate: evaluate}))

    assert_received {:worker, worker}
    refute Process.alive?(worker)
    assert result.best_score == -10
    assert result.failure_count == 1
    assert Enum.any?(result.state.evaluations, &(&1.error == :timeout))
  end

  test "concurrent evaluation obeys the configured limit" do
    observer = self()

    evaluate = fn x ->
      send(observer, {:started, self()})

      receive do
        :finish -> {:ok, x}
      end
    end

    task =
      Task.async(fn ->
        Evolve.run(options([1, 2, 3], [generations: 0, max_concurrency: 2], context: %{evaluate: evaluate}))
      end)

    assert_receive {:started, a}
    assert_receive {:started, b}
    refute_receive {:started, _}, 20
    send(a, :finish)
    assert_receive {:started, c}
    send(b, :finish)
    send(c, :finish)
    assert {:ok, %{evaluation_count: 3}} = Task.await(task)
  end

  test "text strength and adaptive base rate affect mutation" do
    for module <- [Jido.Evolve.Mutation.Text, Jido.Evolve.Mutation.Random, Jido.Evolve.Mutation.AdaptiveText] do
      assert {:ok, "hello"} = module.mutate("hello", rate: 1.0, strength: 0.0)
    end

    assert {:ok, "hello"} = Jido.Evolve.Mutation.AdaptiveText.mutate("hello", rate: 0.0, best_fitness: 1.0)
  end

  test "a killed evaluation is a failure and does not kill the caller" do
    opts =
      options([:kill, -1], [generations: 0],
        context: %{
          evaluate: fn
            :kill -> Process.exit(self(), :kill)
            x -> {:ok, x}
          end
        }
      )

    assert {:ok, result} = Evolve.run(opts)
    assert result.best_score == -1
    assert result.failure_count == 1
    assert Enum.any?(result.state.evaluations, &(&1.error == {:exit, :killed}))
  end

  test "evaluation workers stop when the consuming process dies" do
    observer = self()

    runner =
      spawn(fn ->
        Evolve.run(
          options([1], [evaluation_timeout: :infinity],
            context: %{
              evaluate: fn _ ->
                send(observer, {:worker, self()})

                receive do
                  :finish -> {:ok, 1}
                end
              end
            }
          )
        )
      end)

    assert_receive {:worker, worker}, 1000
    ref = Process.monitor(worker)
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1000
  end

  test "evaluation timeout stops the worker even when the caller is suspended" do
    observer = self()

    runner =
      Task.async(fn ->
        Evolve.run(
          options([1], [generations: 0, evaluation_timeout: 20],
            context: %{
              evaluate: fn _ ->
                send(observer, {:worker, self()})

                receive do
                  :finish -> {:ok, 1}
                end
              end
            }
          )
        )
      end)

    assert_receive {:worker, worker}, 1000
    ref = Process.monitor(worker)
    :erlang.suspend_process(runner.pid)

    try do
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1000
    after
      :erlang.resume_process(runner.pid)
    end

    assert {:error, %{details: %{result: result}}} = Task.await(runner)
    assert [%{error: :timeout}] = result.state.evaluations
  end

  test "cancellation between yields preserves the last complete result" do
    token = Cancellation.new()

    states =
      options([1, 2], [generations: 5], cancellation: token)
      |> Evolve.evolve()
      |> Stream.each(fn state -> if state.generation == 0, do: Cancellation.cancel(token) end)
      |> Enum.to_list()

    assert [initial, terminal] = states
    assert initial.stop_reason == nil
    assert terminal.stop_reason == :cancelled
    assert terminal.evaluation_count == 2
    assert terminal.last_complete_population == [1, 2]
  end

  test "run normalizes raised, thrown, and exit errors from custom operators" do
    for transform <- [
          fn _ -> raise "operator failed" end,
          fn _ -> throw(:operator_failed) end,
          fn _ -> exit(:operator_failed) end
        ] do
      assert {:error, %Error.ExecutionError{}} =
               Evolve.run(options([1], [elitism_rate: 0.0], mutation_opts: [transform: transform]))
    end
  end
end
