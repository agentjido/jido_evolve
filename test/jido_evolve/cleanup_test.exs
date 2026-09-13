defmodule Jido.Evolve.CleanupTest do
  use ExUnit.Case, async: true

  doctest Jido.Evolve.Cleanup

  alias Jido.Evolve
  alias Jido.Evolve.{Cancellation, Cleanup, Config}

  defmodule Fitness do
    @moduledoc false
    use Jido.Evolve.Fitness

    def evaluate(entity, %{evaluate: evaluate}), do: evaluate.(entity)
  end

  defp options(evaluate, config \\ [], extra \\ []) do
    Keyword.merge(
      [
        initial_population: [:case],
        fitness: Fitness,
        context: %{evaluate: evaluate},
        config: Keyword.merge([generations: 0, evaluation_timeout: 1000, cleanup_timeout: 1000], config)
      ],
      extra
    )
  end

  defp detached_resource(owner) do
    {:ok, child} = Agent.start(fn -> :external_work end)
    worker = self()

    :ok =
      Cleanup.register(fn reason ->
        Agent.stop(child)
        send(owner, {:cleaned, worker, child, reason, self()})
        :ok
      end)

    send(owner, {:registered, worker, child})
    child
  end

  test "registration requires a callback and a one-argument function" do
    assert {:error, :not_in_callback} = Cleanup.register(fn _ -> :ok end)
    assert {:error, :invalid_hook} = Cleanup.register(fn -> :ok end)
    assert {:error, :invalid_hook} = Cleanup.register(:invalid)
  end

  test "cleanup has a positive finite budget" do
    assert {:ok, %{cleanup_timeout: 1000}} = Config.new()
    assert {:ok, %{cleanup_timeout: 250}} = Config.new(cleanup_timeout: 250)

    for value <- [0, -1, :infinity] do
      assert {:error, _} = Config.new(cleanup_timeout: value)
    end
  end

  test "normal completion cleans detached resources before returning the score" do
    owner = self()

    evaluate = fn _ ->
      detached_resource(owner)
      {:ok, 1}
    end

    assert {:ok, %{best_score: 1}} = Evolve.run(options(evaluate))
    assert_received {:registered, worker, child}
    assert_received {:cleaned, ^worker, ^child, :completed, cleaner}
    assert cleaner != worker
    refute Process.alive?(child)
    refute_received {:cleaned, _, _, _, _}
  end

  test "an evaluation timeout cleans detached work without relying on the worker after block" do
    owner = self()

    evaluate = fn _ ->
      detached_resource(owner)

      try do
        Process.sleep(:infinity)
      after
        send(owner, :after_ran)
      end
    end

    assert {:error, %{details: %{result: result}}} = Evolve.run(options(evaluate, evaluation_timeout: 100))
    assert [%{error: :timeout}] = result.state.evaluations
    assert_received {:registered, worker, child}
    assert_received {:cleaned, ^worker, ^child, :timeout, _}
    refute Process.alive?(worker)
    refute Process.alive?(child)
    refute_received :after_ran
  end

  test "cancellation stops all workers before waiting for their cleanup and skips queued work" do
    owner = self()
    token = Cancellation.new()

    evaluate = fn entity ->
      worker = self()
      {:ok, child} = Agent.start(fn -> entity end)

      :ok =
        Cleanup.register(fn reason ->
          send(owner, {:cleaning, entity, worker, self(), reason})

          receive do
            :finish -> Agent.stop(child)
          end
        end)

      send(owner, {:started, entity, worker, child})
      Process.sleep(:infinity)
    end

    task =
      Task.async(fn ->
        Evolve.run(
          options(evaluate, [max_concurrency: 2, evaluation_timeout: :infinity],
            initial_population: [:a, :b, :queued],
            cancellation: token
          )
        )
      end)

    assert_receive {:started, :a, worker_a, child_a}, 1000
    assert_receive {:started, :b, worker_b, child_b}, 1000
    Cancellation.cancel(token)
    assert_receive {:cleaning, :a, ^worker_a, cleaner_a, :cancelled}, 1000
    assert_receive {:cleaning, :b, ^worker_b, cleaner_b, :cancelled}, 1000
    refute Process.alive?(worker_a)
    refute Process.alive?(worker_b)
    assert Task.yield(task, 0) == nil
    send(cleaner_a, :finish)
    send(cleaner_b, :finish)
    assert {:error, %{details: %{result: result}}} = Task.await(task)
    assert result.stop_reason == :cancelled
    assert result.evaluation_count == 2
    refute Process.alive?(child_a)
    refute Process.alive?(child_b)
    refute_received {:started, :queued, _, _}
  end

  test "the overall deadline cleans external work and preserves the completed result" do
    owner = self()

    evaluate = fn
      :fast ->
        {:ok, 3}

      :slow ->
        detached_resource(owner)
        Process.sleep(:infinity)
    end

    assert {:ok, result} =
             Evolve.run(
               options(evaluate, [deadline_ms: 100, evaluation_timeout: :infinity, max_concurrency: 1],
                 initial_population: [:fast, :slow]
               )
             )

    assert result.best_score == 3
    assert result.stop_reason == :deadline
    assert_received {:registered, worker, child}
    assert_received {:cleaned, ^worker, ^child, :deadline, _}
    refute Process.alive?(child)
  end

  test "worker crashes also clean detached resources" do
    owner = self()

    evaluate = fn _ ->
      detached_resource(owner)
      Process.exit(self(), :kill)
    end

    assert {:error, %{details: %{result: result}}} = Evolve.run(options(evaluate))
    assert [%{error: {:exit, :killed}}] = result.state.evaluations
    assert_received {:registered, worker, child}
    assert_received {:cleaned, ^worker, ^child, {:exit, :killed}, _}
    refute Process.alive?(child)
  end

  test "the overall deadline cleans resources even while the search caller is suspended" do
    owner = self()

    evaluate = fn _ ->
      detached_resource(owner)
      Process.sleep(:infinity)
    end

    task = Task.async(fn -> Evolve.run(options(evaluate, deadline_ms: 100, evaluation_timeout: :infinity)) end)
    assert_receive {:registered, worker, child}, 1000
    :erlang.suspend_process(task.pid)

    try do
      assert_receive {:cleaned, ^worker, ^child, :deadline, _}, 1000
      refute Process.alive?(child)
    after
      :erlang.resume_process(task.pid)
    end

    assert {:error, %{details: %{result: result}}} = Task.await(task)
    assert result.stop_reason == :deadline
  end

  test "cleanup continues after the search caller dies" do
    owner = self()

    evaluate = fn _ ->
      detached_resource(owner)
      Process.sleep(:infinity)
    end

    runner = spawn(fn -> Evolve.run(options(evaluate, evaluation_timeout: :infinity)) end)
    assert_receive {:registered, worker, child}, 1000
    Process.exit(runner, :kill)
    assert_receive {:cleaned, ^worker, ^child, _reason, _}, 1000
    refute Process.alive?(worker)
    refute Process.alive?(child)
  end

  test "blocked cleanup functions share a single budget and are killed before return" do
    owner = self()

    evaluate = fn _ ->
      for _ <- 1..3 do
        :ok =
          Cleanup.register(fn _reason ->
            send(owner, {:blocked_cleanup, self()})
            Process.sleep(:infinity)
          end)
      end

      {:ok, 1}
    end

    started = System.monotonic_time(:millisecond)
    assert {:error, %{details: %{result: result}}} = Evolve.run(options(evaluate, cleanup_timeout: 100))
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 500
    assert [%{error: {:cleanup_failed, {_finished, {:ok, 1}}, failures}}] = result.state.evaluations
    assert failures == [:timeout, :timeout, :timeout]

    for _ <- 1..3 do
      assert_received {:blocked_cleanup, cleaner}
      refute Process.alive?(cleaner)
    end
  end

  test "cleanup errors are recorded and do not prevent other cleanup functions" do
    owner = self()

    evaluate = fn _ ->
      detached_resource(owner)
      :ok = Cleanup.register(fn _ -> {:error, :unavailable} end)
      :ok = Cleanup.register(fn _ -> raise "cleanup failed" end)
      :ok = Cleanup.register(fn _ -> throw(:cleanup_failed) end)
      :ok = Cleanup.register(fn _ -> :invalid end)
      :ok = Cleanup.register(fn _ -> {:error, nil} end)
      :ok = Cleanup.register(fn _ -> {:error, false} end)
      {:ok, 1}
    end

    assert {:error, %{details: %{result: result}}} = Evolve.run(options(evaluate))
    assert [%{error: {:cleanup_failed, {_finished, {:ok, 1}}, failures}}] = result.state.evaluations
    assert :unavailable in failures
    assert {:throw, :cleanup_failed} in failures
    assert {:invalid_result, :invalid} in failures
    assert nil in failures
    assert false in failures
    assert Enum.any?(failures, &match?({:exception, %RuntimeError{}}, &1))
    assert_received {:registered, worker, child}
    assert_received {:cleaned, ^worker, ^child, :completed, _}
    refute Process.alive?(child)
  end

  test "cleanup time does not turn an on-time callback result into an evaluation timeout" do
    evaluate = fn _ ->
      :ok = Cleanup.register(fn _ -> Process.sleep(100) end)
      {:ok, 2}
    end

    assert {:ok, %{best_score: 2}} = Evolve.run(options(evaluate, evaluation_timeout: 50))
  end

  test "a cleanup process crash is distinct from a cleanup timeout" do
    evaluate = fn _ ->
      :ok = Cleanup.register(fn _ -> Process.exit(self(), :kill) end)
      {:ok, 1}
    end

    assert {:error, %{details: %{result: result}}} = Evolve.run(options(evaluate))
    assert [%{error: {:cleanup_failed, _, [{:exit, :killed}]}}] = result.state.evaluations
  end

  test "failed cancellation cleanup does not mark an interrupted population complete" do
    owner = self()
    token = Cancellation.new()

    evaluate = fn _ ->
      :ok = Cleanup.register(fn :cancelled -> Process.sleep(:infinity) end)
      send(owner, :ready_to_cancel)
      Process.sleep(:infinity)
    end

    task =
      Task.async(fn ->
        Evolve.run(options(evaluate, [cleanup_timeout: 100, evaluation_timeout: :infinity], cancellation: token))
      end)

    assert_receive :ready_to_cancel, 1000
    Cancellation.cancel(token)
    assert {:error, %{details: %{result: result}}} = Task.await(task)
    assert result.stop_reason == :cancelled
    assert result.population == nil
    refute result.state.complete

    assert [%{status: :cancelled, error: {:cleanup_failed, {:stopped, :cancelled}, [:timeout]}}] =
             result.state.evaluations
  end

  test "spawned processes cannot register against their parent callback" do
    evaluate = fn _ ->
      assert Task.async(fn -> Cleanup.register(fn _ -> :ok end) end) |> Task.await() == {:error, :not_in_callback}
      :ok = Cleanup.register(fn _ -> {:ok, :closed} end)
      {:ok, 1}
    end

    assert {:ok, %{best_score: 1}} = Evolve.run(options(evaluate))
  end
end
