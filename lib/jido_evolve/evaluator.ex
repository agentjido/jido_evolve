defmodule Jido.Evolve.Evaluator do
  @moduledoc false

  alias Jido.Evolve.{Callback, Cancellation, Evaluation}

  @doc false
  @spec evaluate(list(), non_neg_integer(), map(), integer() | nil) ::
          {list(Evaluation.t()), non_neg_integer(), atom() | nil}
  def evaluate(population, generation, opts, deadline) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      queue = Enum.with_index(population) |> Enum.map(fn {entity, index} -> {{generation, index}, entity} end)
      collect(queue, %{}, [], 0, supervisor, opts, deadline)
    after
      Supervisor.stop(supervisor)
    end
  end

  @doc false
  @spec stop_reason(map(), integer() | nil) :: :cancelled | :deadline | nil
  def stop_reason(opts, deadline) do
    cond do
      Cancellation.cancelled?(opts.cancellation) -> :cancelled
      deadline != nil and now() >= deadline -> :deadline
      true -> nil
    end
  end

  defp collect([], running, results, count, _supervisor, _opts, _deadline) when map_size(running) == 0 do
    {ordered(results), count, completed_reason(results)}
  end

  defp collect(queue, running, results, count, supervisor, opts, deadline) do
    case stop_reason(opts, deadline) do
      nil ->
        {queue, running, count} = schedule(queue, running, count, supervisor, opts, deadline)
        await(queue, running, results, count, supervisor, opts, deadline)

      reason ->
        Enum.each(running, fn {_ref, {task, _id, _entity, _expires}} -> Callback.cancel(task, reason) end)

        drain(running, results, count, reason, deadline)
    end
  end

  defp drain(running, results, count, reason, _deadline) when map_size(running) == 0 do
    {ordered(results), count, reason}
  end

  defp drain(running, results, count, reason, deadline) do
    receive do
      {ref, result} when is_map_key(running, ref) ->
        {{_task, id, entity, expires}, running} = Map.pop(running, ref)
        Process.demonitor(ref, [:flush])
        drain(running, [record(id, entity, result, expires, deadline) | results], count, reason, deadline)

      {:DOWN, ref, :process, _pid, error} when is_map_key(running, ref) ->
        {{_task, id, entity, _expires}, running} = Map.pop(running, ref)
        record = Evaluation.failure(id, entity, :error, {:exit, error})
        drain(running, [record | results], count, reason, deadline)
    end
  end

  defp schedule([], running, count, _supervisor, _opts, _deadline), do: {[], running, count}

  defp schedule(queue, running, count, supervisor, opts, deadline) do
    if map_size(running) < opts.config.max_concurrency and stop_reason(opts, deadline) == nil do
      [{id, entity} | rest] = queue
      seed = :rand.uniform(1_000_000_000)
      timeout = opts.config.evaluation_timeout
      expires = if timeout == :infinity, do: nil, else: now() + timeout
      {stop_at, reason} = callback_deadline(expires, deadline)

      task =
        Callback.async(supervisor, fn -> execute(entity, opts, seed) end, stop_at, opts.config.cleanup_timeout, reason)

      schedule(rest, Map.put(running, task.ref, {task, id, entity, expires}), count + 1, supervisor, opts, deadline)
    else
      {queue, running, count}
    end
  end

  defp callback_deadline(expires, nil), do: {expires, :timeout}
  defp callback_deadline(nil, deadline), do: {deadline, :deadline}
  defp callback_deadline(expires, deadline) when deadline <= expires, do: {deadline, :deadline}
  defp callback_deadline(expires, _deadline), do: {expires, :timeout}

  defp await([], running, results, count, _supervisor, _opts, _deadline) when map_size(running) == 0 do
    {ordered(results), count, completed_reason(results)}
  end

  defp await(queue, running, results, count, supervisor, opts, deadline) do
    receive do
      {ref, result} when is_map_key(running, ref) ->
        {{_task, id, entity, expires}, running} = Map.pop(running, ref)
        Process.demonitor(ref, [:flush])
        record = record(id, entity, result, expires, deadline)
        collect(queue, running, [record | results], count, supervisor, opts, deadline)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        {{_task, id, entity, _expires}, running} = Map.pop(running, ref)
        record = Evaluation.failure(id, entity, :error, {:exit, reason})
        collect(queue, running, [record | results], count, supervisor, opts, deadline)
    after
      5 ->
        collect(queue, running, results, count, supervisor, opts, deadline)
    end
  end

  defp completed_reason(results) do
    if Enum.any?(results, &(&1.status == :cancelled)), do: :deadline, else: nil
  end

  defp record(id, entity, {finished, result}, expires, deadline) when is_integer(finished) do
    cond do
      expires != nil and finished > expires -> Evaluation.failure(id, entity, :error, :timeout)
      deadline != nil and finished >= deadline -> Evaluation.failure(id, entity, :cancelled, :deadline)
      true -> Evaluation.new(id, entity, result)
    end
  end

  defp record(id, entity, {:stopped, reason}, _expires, _deadline) when reason in [:cancelled, :deadline] do
    Evaluation.failure(id, entity, :cancelled, reason)
  end

  defp record(id, entity, {:stopped, reason}, _expires, _deadline) do
    Evaluation.failure(id, entity, :error, reason)
  end

  defp record(id, entity, {:cleanup_failed, {:stopped, reason}, _failures} = error, _expires, _deadline)
       when reason in [:cancelled, :deadline] do
    Evaluation.failure(id, entity, :cancelled, error)
  end

  defp record(id, entity, error, _expires, _deadline), do: Evaluation.failure(id, entity, :error, error)

  defp execute(entity, opts, seed) do
    :rand.seed(:exs1024, {seed, seed * 2, seed * 4})
    opts.fitness.evaluate(entity, opts.context)
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp ordered(results), do: Enum.sort_by(results, & &1.id)
  defp now, do: System.monotonic_time(:millisecond)
end
