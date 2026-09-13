defmodule Jido.Evolve.Selection.TournamentTest do
  use ExUnit.Case, async: true

  alias Jido.Evolve.Selection.Tournament

  describe "select/4" do
    test "handles negative scores without errors" do
      population = ["a", "b", "c", "d"]
      scores = %{"a" => -10.0, "b" => -5.0, "c" => -15.0, "d" => -2.0}

      selected = Tournament.select(population, scores, 10, tournament_size: 2)

      assert length(selected) == 10
      assert Enum.all?(selected, &(&1 in population))
    end

    test "handles mix of negative and positive scores" do
      population = ["a", "b", "c", "d"]
      scores = %{"a" => -100.0, "b" => 50.0, "c" => -50.0, "d" => 100.0}

      selected = Tournament.select(population, scores, 10, tournament_size: 2)

      assert length(selected) == 10
      assert Enum.all?(selected, &(&1 in population))
    end

    test "favors higher scores over many trials" do
      population = ["low", "high"]
      scores = %{"low" => -100.0, "high" => 100.0}

      # Run many tournaments
      selected = Tournament.select(population, scores, 1000, tournament_size: 2)

      # Count selections
      counts = Enum.frequencies(selected)
      high_count = Map.get(counts, "high", 0)
      low_count = Map.get(counts, "low", 0)

      # Higher score should be selected significantly more often
      assert high_count > low_count * 2
    end

    test "with uniform scores, selection approximates uniform distribution" do
      population = ["a", "b", "c", "d"]
      scores = %{"a" => 5.0, "b" => 5.0, "c" => 5.0, "d" => 5.0}

      selected = Tournament.select(population, scores, 1000, tournament_size: 2)

      counts = Enum.frequencies(selected)

      # Each entity should be selected roughly equally (within 40% tolerance)
      expected = 250
      tolerance = 100

      Enum.each(population, fn entity ->
        count = Map.get(counts, entity, 0)

        assert count >= expected - tolerance and count <= expected + tolerance,
               "Entity #{entity} selected #{count} times, expected ~#{expected}"
      end)
    end

    test "edge case: all same scores (constant fitness)" do
      population = ["a", "b", "c"]
      scores = %{"a" => -42.0, "b" => -42.0, "c" => -42.0}

      selected = Tournament.select(population, scores, 100, tournament_size: 2)

      assert length(selected) == 100
      assert Enum.all?(selected, &(&1 in population))

      # Should distribute relatively evenly
      counts = Enum.frequencies(selected)
      # More than one entity selected
      assert map_size(counts) > 1
    end

    test "edge case: very large negative and positive scores" do
      population = ["a", "b", "c"]
      scores = %{"a" => -1_000_000.0, "b" => 0.0, "c" => 1_000_000.0}

      selected = Tournament.select(population, scores, 100, tournament_size: 3)

      assert length(selected) == 100
      assert Enum.all?(selected, &(&1 in population))

      counts = Enum.frequencies(selected)
      # "c" should be selected most often due to highest score
      assert Map.get(counts, "c", 0) > Map.get(counts, "a", 0)
    end

    test "rejects the removed pressure option" do
      assert {:error, _} = Tournament.validate_opts(pressure: 0.5)
      assert Tournament.select(["a"], %{"a" => 1}, 1, pressure: 0.5) == []
    end

    test "preserves ordering after normalization" do
      population = ["worst", "bad", "ok", "good", "best"]

      scores = %{
        "worst" => -100.0,
        "bad" => -50.0,
        "ok" => 0.0,
        "good" => 50.0,
        "best" => 100.0
      }

      # Run many tournaments with smaller tournament size to get distribution
      selected = Tournament.select(population, scores, 2000, tournament_size: 3)

      counts = Enum.frequencies(selected)

      # Verify ordering is generally preserved (higher scores selected more often)
      # "best" should be selected most
      assert Map.get(counts, "best", 0) > Map.get(counts, "good", 0)
      # "worst" should be selected least
      assert Map.get(counts, "best", 0) > Map.get(counts, "worst", 0)
      assert Map.get(counts, "good", 0) > Map.get(counts, "worst", 0)
    end

    test "returns empty list for empty population" do
      assert Tournament.select([], %{}, 5) == []
    end

    test "returns empty list for empty scores" do
      assert Tournament.select(["a", "b"], %{}, 5) == []
    end

    test "returns empty list for invalid options" do
      population = ["a", "b"]
      scores = %{"a" => 1.0, "b" => 2.0}

      assert Tournament.select(population, scores, 5, tournament_size: 0) == []
      assert Tournament.select(population, scores, 5, :invalid) == []
    end

    test "handles tournament size larger than population" do
      population = ["a", "b"]
      scores = %{"a" => 1.0, "b" => 2.0}

      selected = Tournament.select(population, scores, 10, tournament_size: 10)

      assert length(selected) == 10
      assert Enum.all?(selected, &(&1 in population))
    end

    test "negative scores are ranked without normalization" do
      population = ["a", "b", "c"]
      scores = %{"a" => -9.0, "b" => -4.0, "c" => -1.0}

      # This would fail with direct exponentiation of negative numbers
      selected = Tournament.select(population, scores, 100, tournament_size: 2)

      assert length(selected) == 100
      assert Enum.all?(selected, &(&1 in population))

      # Higher (less negative) score should still be favored
      counts = Enum.frequencies(selected)
      assert Map.get(counts, "c", 0) > Map.get(counts, "a", 0)
    end

    test "respects tournament_size option" do
      population = ["a", "b", "c", "d", "e", "f"]
      scores = %{"a" => 1.0, "b" => 2.0, "c" => 3.0, "d" => 4.0, "e" => 5.0, "f" => 6.0}

      # With tournament_size=1, selection is random (since only 1 candidate)
      selected_size_1 = Tournament.select(population, scores, 500, tournament_size: 1)
      counts_1 = Enum.frequencies(selected_size_1)

      # With tournament_size=6 (whole population), best always wins
      selected_size_6 = Tournament.select(population, scores, 500, tournament_size: 6)
      counts_6 = Enum.frequencies(selected_size_6)

      # Size 1 should have more diverse distribution
      assert map_size(counts_1) > 1, "Size 1 tournaments should select multiple entities"

      # Size 6 should heavily favor "f" (best entity)
      assert Map.get(counts_6, "f", 0) > 400, "Size 6 tournaments should mostly select best"
    end
  end
end
