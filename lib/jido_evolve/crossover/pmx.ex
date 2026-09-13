defmodule Jido.Evolve.Crossover.PMX do
  @moduledoc """
  Partially Mapped Crossover (PMX) for permutations.

  PMX preserves permutation validity by mapping conflicting values
  when copying segments between parents.

  ## Algorithm

  1. Select two random crossover points
  2. Copy the segment from parent1 to child
  3. For remaining positions, use mapping from parent2
  4. If value conflicts, follow the mapping chain

  ## Example

      parent1 = [0, 1, 2, 3, 4, 5, 6, 7, 8]
      parent2 = [1, 2, 3, 5, 4, 6, 8, 7, 0]
      
      # Cut points at 3 and 6
      child   = [_, _, _, 3, 4, 5, _, _, _]
      
      # Fill remaining using mapping
      child   = [0, 1, 2, 3, 4, 5, 6, 7, 8]
  """

  @behaviour Jido.Evolve.Crossover

  @impl true
  def crossover(parent1, parent2, _config) when is_list(parent1) and is_list(parent2) do
    n = length(parent1)

    if n != length(parent2) or n < 2 or length(Enum.uniq(parent1)) != n or MapSet.new(parent1) != MapSet.new(parent2) do
      # Return parents unchanged if invalid
      {parent1, parent2}
    else
      # Select two random crossover points
      point1 = :rand.uniform(n) - 1
      point2 = :rand.uniform(n) - 1
      {cut1, cut2} = if point1 <= point2, do: {point1, point2}, else: {point2, point1}

      # Create both children
      child1 = pmx_child(parent1, parent2, cut1, cut2)
      child2 = pmx_child(parent2, parent1, cut1, cut2)

      {child1, child2}
    end
  end

  def crossover(parent1, parent2, _config) do
    # Invalid types - return parents unchanged
    {parent1, parent2}
  end

  # Create a single child using PMX
  defp pmx_child(p1, p2, cut1, cut2) do
    n = length(p1)

    # Start with parent2 as base
    child = List.to_tuple(p2)

    # Copy segment from parent1 to child
    child =
      Enum.reduce(cut1..cut2, child, fn i, acc ->
        put_elem(acc, i, Enum.at(p1, i))
      end)

    # Build mapping: p1[i] -> p2[i] for segment
    # This maps segment values in p1 to their corresponding p2 values
    mapping =
      cut1..cut2
      |> Enum.map(fn i -> {Enum.at(p1, i), Enum.at(p2, i)} end)
      |> Map.new()

    # Fix conflicts outside segment
    child =
      Enum.reduce(0..(n - 1), child, fn i, acc ->
        if i >= cut1 and i <= cut2 do
          # Inside segment, already set
          acc
        else
          # Outside segment, check for conflicts
          # The child currently has p2's value at position i
          # We need to check if this value conflicts with values from p1's segment
          p2_value = elem(acc, i)

          if Map.has_key?(mapping, p2_value) do
            # Value conflicts with segment, follow mapping chain
            new_value = follow_mapping(p2_value, mapping)
            put_elem(acc, i, new_value)
          else
            # No conflict
            acc
          end
        end
      end)

    Tuple.to_list(child)
  end

  # Follow mapping chain to find non-conflicting value
  defp follow_mapping(value, mapping) do
    case Map.get(mapping, value) do
      nil ->
        # No mapping found, return value
        value

      mapped_value ->
        # Check if mapped value is also a key (creates chain)
        if Map.has_key?(mapping, mapped_value) do
          follow_mapping(mapped_value, mapping)
        else
          mapped_value
        end
    end
  end
end
