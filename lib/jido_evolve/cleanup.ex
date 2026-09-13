defmodule Jido.Evolve.Cleanup do
  @moduledoc """
  Register cleanup for external work owned by an evaluation or reflection callback.

  A separate process stores each function before `register/1` returns. It runs
  the functions after the callback stops, including when the worker is killed.
  Functions run concurrently, once per registration, on success and failure.
  They share one `cleanup_timeout` budget (default: 1,000 milliseconds).

  Return `:ok` or `{:ok, value}` after cleanup completes. Errors, exceptions,
  and cleanup timeouts make the callback fail with `:cleanup_failed` details.
  Functions must be idempotent and must not depend on the callback process.

  Register a function that uses a stable resource ID before starting external
  work when the client supports this. Starting work before registration leaves
  a gap where termination can prevent registration. The caller must cover that
  gap with an external owner or a service deadline. Unregistered work, a stopped
  VM, and external services that ignore cancellation remain caller responsibilities.

  Registration is available only in the evaluation or reflection worker itself.
  It is not inherited by spawned processes or supported in variation callbacks.
  A callback's `after` block is not a substitute for registered cleanup.
  """

  @type reason :: :completed | :timeout | :cancelled | :deadline | :owner_down | {:exit, term()}
  @type hook :: (reason() -> :ok | {:ok, term()} | {:error, term()})

  @doc """
  Register cleanup with the current callback's owner.

  Capture a resource ID in the function. It also receives the stop reason.
  For example, inside a fitness or reflection callback:

      run_id = MyClient.new_run_id()
      :ok = Jido.Evolve.Cleanup.register(fn _reason -> MyClient.cancel(run_id) end)
      MyClient.run(run_id)

  Outside a supported callback:

      iex> Jido.Evolve.Cleanup.register(fn _reason -> :ok end)
      {:error, :not_in_callback}
  """
  @spec register(hook()) :: :ok | {:error, :not_in_callback | :invalid_hook}
  def register(fun) when is_function(fun, 1) do
    case Process.get(__MODULE__) do
      nil -> {:error, :not_in_callback}
      owner -> GenServer.call(owner, {:register_cleanup, fun})
    end
  end

  def register(_fun), do: {:error, :invalid_hook}
end
