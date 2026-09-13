Code.require_file("../../../examples/gepa/search.exs", __DIR__)
Code.require_file("../../../examples/gepa/routing.exs", __DIR__)

defmodule GEPAExampleTest do
  use ExUnit.Case, async: true

  alias GEPAExample.{Mock, Models, Routing, Search}

  defp options(overrides \\ []) do
    Keyword.merge(
      [
        seed_candidate: %{"instructions" => "seed"},
        trainset: [%{id: "train", input: "training input"}],
        valset: [%{id: "val", input: "validation input"}],
        evaluate: fn candidate, _item -> {:ok, if(candidate["instructions"] == "seed", do: 0.0, else: 1.0)} end,
        reflect: fn _candidate, _component, _records -> {:ok, "proposal"} end,
        max_reflections: 1,
        max_evaluations: 4
      ],
      overrides
    )
  end

  test "the fixture improves on validation and separate test cases" do
    data = Routing.data()

    {:ok, result} =
      Search.run(
        options(
          seed_candidate: Routing.seed(),
          trainset: data.train,
          valset: data.validation,
          evaluate: &Mock.evaluate/2,
          reflect: &Mock.reflect/3,
          max_evaluations: 120,
          max_reflections: 12
        )
      )

    assert hd(result.archive).validation_score == 0.0
    assert result.best_score == 1.0
    assert result.metric_calls <= 120
    assert result.reflection_calls <= 12
    assert Enum.any?(result.trace, &(&1.status == :rejected))
    assert Enum.any?(result.trace, &(&1.status == :accepted))
    {:ok, test_records} = Search.evaluate_cases(result.best_candidate, data.test, &Mock.evaluate/2)
    assert Enum.all?(test_records, &(&1.score == 1.0))
  end

  test "parent and proposal use the same batch and reflection sees only training records" do
    owner = self()

    evaluate = fn candidate, item ->
      send(owner, {:evaluated, candidate["instructions"], item.id})
      {:ok, %{score: if(candidate["instructions"] == "seed", do: 0.0, else: 1.0), feedback: item.id}}
    end

    reflect = fn _candidate, component, records ->
      send(owner, {:reflected, component, records})
      {:ok, "proposal"}
    end

    {:ok, result} = Search.run(options(evaluate: evaluate, reflect: reflect))
    assert result.metric_calls == 4
    assert result.reflection_calls == 1
    assert_receive {:evaluated, "seed", "val"}
    assert_receive {:evaluated, "seed", "train"}
    assert_receive {:reflected, "instructions", [%{case_id: "train", feedback: "train"}]}
    assert_receive {:evaluated, "proposal", "train"}
    assert_receive {:evaluated, "proposal", "val"}
    refute_receive {:evaluated, _, _}
  end

  test "validation selects the final candidate even when training improves" do
    evaluate = fn candidate, item ->
      score = if candidate["instructions"] == "seed" == (item.id == "val"), do: 1.0, else: 0.0
      {:ok, score}
    end

    {:ok, result} = Search.run(options(evaluate: evaluate))
    assert length(result.archive) == 2
    assert result.best_candidate == %{"instructions" => "seed"}
    assert result.best_score == 1.0
  end

  test "the search reserves a full parent, trial, and validation batch" do
    {:ok, result} = Search.run(options(max_evaluations: 3))
    assert result.metric_calls == 1
    assert result.reflection_calls == 0
    assert result.stop_reason == :max_evaluations
    assert result.trace == []
  end

  test "case champions survive even when their average scores tie" do
    archive = [
      %{id: 0, validation_scores: %{"a" => 1.0, "b" => 0.0}},
      %{id: 1, validation_scores: %{"a" => 0.0, "b" => 1.0}},
      %{id: 2, validation_scores: %{"a" => 0.5, "b" => 0.5}},
      %{id: 3, validation_scores: %{"a" => 1.0, "b" => 1.0}}
    ]

    assert Search.frontier(archive) == %{"a" => [0, 3], "b" => [1, 3]}
  end

  test "an evaluator error stops search and preserves the last valid archive" do
    evaluate = fn _candidate, item ->
      if item.id == "val", do: {:ok, 0.0}, else: {:error, :service_unavailable}
    end

    assert {:error, %{reason: {:evaluation_failed, :parent_train, _}, partial_result: result}} =
             Search.run(options(evaluate: evaluate))

    assert result.metric_calls == 2
    assert result.reflection_calls == 0
    assert result.best_candidate == %{"instructions" => "seed"}
  end

  test "reflection timeout stops its worker and preserves the archive" do
    owner = self()

    reflect = fn _, _, _ ->
      send(owner, {:worker, self()})
      Process.sleep(:infinity)
    end

    assert {:error, %{reason: {:reflection_failed, {:error, :timeout}}, partial_result: result}} =
             Search.run(options(reflect: reflect, reflection_timeout: 20))

    assert_receive {:worker, pid}
    refute Process.alive?(pid)
    assert result.reflection_calls == 1
    assert result.metric_calls == 2
  end

  test "reflection timeout cleans detached work before returning the archive" do
    owner = self()

    reflect = fn _, _, _ ->
      {:ok, child} = Agent.start(fn -> :external_work end)

      :ok =
        Jido.Evolve.Cleanup.register(fn reason ->
          Agent.stop(child)
          send(owner, {:reflection_cleaned, child, reason})
          :ok
        end)

      try do
        Process.sleep(:infinity)
      after
        send(owner, :reflection_after_ran)
      end
    end

    assert {:error, %{reason: {:reflection_failed, {:error, :timeout}}, partial_result: result}} =
             Search.run(options(reflect: reflect, reflection_timeout: 100))

    assert_received {:reflection_cleaned, child, :timeout}
    refute Process.alive?(child)
    refute_received :reflection_after_ran
    assert result.best_candidate == %{"instructions" => "seed"}
    assert result.reflection_calls == 1
  end

  test "reflection cleanup timeout is bounded and preserves the partial archive" do
    owner = self()

    reflect = fn _, _, _ ->
      :ok =
        Jido.Evolve.Cleanup.register(fn :completed ->
          send(owner, {:reflection_cleanup, self()})
          Process.sleep(:infinity)
        end)

      {:ok, "proposal"}
    end

    started = System.monotonic_time(:millisecond)

    assert {:error,
            %{
              reason: {:reflection_failed, {:error, {:cleanup_failed, _, [:timeout]}}},
              partial_result: result
            }} = Search.run(options(reflect: reflect, cleanup_timeout: 100))

    assert System.monotonic_time(:millisecond) - started < 500
    assert_received {:reflection_cleanup, cleaner}
    refute Process.alive?(cleaner)
    assert result.best_candidate == %{"instructions" => "seed"}
  end

  test "successful reflections clean resources before evaluating the proposal" do
    owner = self()

    reflect = fn _, _, _ ->
      :ok =
        Jido.Evolve.Cleanup.register(fn :completed ->
          send(owner, :reflection_complete)
          :ok
        end)

      {:ok, "proposal"}
    end

    assert {:ok, result} = Search.run(options(reflect: reflect))
    assert result.best_candidate == %{"instructions" => "proposal"}
    assert_received :reflection_complete
  end

  test "GEPA evaluation callbacks use the configured cleanup budget" do
    evaluate = fn _, _ ->
      :ok = Jido.Evolve.Cleanup.register(fn _ -> Process.sleep(:infinity) end)
      {:ok, 1}
    end

    started = System.monotonic_time(:millisecond)
    assert {:error, _} = Search.run(options(evaluate: evaluate, cleanup_timeout: 100))
    assert System.monotonic_time(:millisecond) - started < 500
    assert {:error, %{reason: :invalid_limit}} = Search.run(options(cleanup_timeout: :infinity))
  end

  test "overlapping case IDs and a budget smaller than validation are rejected" do
    assert {:error, %{reason: :overlapping_or_duplicate_case_ids}} =
             Search.run(options(valset: [%{id: "train", input: "leaked input"}]))

    assert {:error, %{reason: :budget_smaller_than_validation}} =
             Search.run(
               options(
                 max_evaluations: 1,
                 valset: [
                   %{id: "val-a", input: "a"},
                   %{id: "val-b", input: "b"}
                 ]
               )
             )
  end

  test "fixed seeds repeat results without changing the caller random state" do
    :rand.seed(:exsss, 123)
    before = :rand.export_seed()
    assert Search.run(options()) == Search.run(options())
    assert :rand.export_seed() == before
  end

  test "model task input excludes the reference answer and returns useful feedback" do
    generate = fn messages ->
      assert List.last(messages) == %{role: :user, content: "Please help."}
      refute inspect(messages) =~ "secret_expected_label"
      {:ok, "wrong"}
    end

    evaluate = Models.evaluator(generate)

    assert {:ok, result} =
             evaluate.(Routing.seed(), %{id: "train", input: "Please help.", expected: "secret_expected_label"})

    assert result.score == 0.0
    assert result.feedback.expected == "secret_expected_label"
    assert result.metadata.output == "wrong"
  end

  test "model reflection receives the selected component and full training feedback" do
    generate = fn messages ->
      payload = Jason.decode!(List.last(messages).content)
      assert payload["component"] == "instructions"
      assert hd(payload["records"])["feedback"] == "Use the right label."
      {:ok, " New instruction. \n"}
    end

    reflect = Models.reflector(generate)

    assert {:ok, "New instruction."} =
             reflect.(Routing.seed(), "instructions", [%{case_id: "train", feedback: "Use the right label."}])
  end
end
