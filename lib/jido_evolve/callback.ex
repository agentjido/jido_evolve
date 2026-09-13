defmodule Jido.Evolve.Callback do
  @moduledoc false

  use GenServer

  alias Jido.Evolve.Cleanup

  @enforce_keys [:pid, :ref]
  defstruct [:pid, :ref]

  @type t :: %__MODULE__{pid: pid(), ref: reference()}
  @type outcome ::
          {integer(), term()}
          | {:stopped, Cleanup.reason()}
          | {:exit, term()}
          | {:cleanup_failed, term(), list()}

  @doc false
  @spec async(pid(), (-> term()), integer() | nil, pos_integer(), :timeout | :deadline) :: t()
  def async(supervisor, fun, expires, cleanup_timeout, timeout_reason \\ :timeout) do
    {:ok, pid} = GenServer.start(__MODULE__, {self(), cleanup_timeout})
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:start, ref, supervisor, fun, expires, timeout_reason})
    %__MODULE__{pid: pid, ref: ref}
  end

  @doc false
  @spec cancel(t(), Cleanup.reason()) :: :ok
  def cancel(%__MODULE__{pid: pid}, reason), do: GenServer.cast(pid, {:cancel, reason})

  @doc false
  @spec await(t()) :: {:ok, term()} | {:error, term()}
  def await(%__MODULE__{pid: pid, ref: ref}) do
    receive do
      {^ref, outcome} ->
        Process.demonitor(ref, [:flush])
        reply(outcome)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:exit, reason}}
    end
  end

  @impl true
  def init({owner, cleanup_timeout}) do
    {:ok,
     %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       ref: nil,
       task: nil,
       expires: nil,
       timeout_reason: :timeout,
       timer: nil,
       hooks: [],
       phase: :starting,
       cleanup_timeout: cleanup_timeout,
       cleanup_deadline: nil,
       cleanup_expired: false,
       pending: %{},
       failures: [],
       outcome: nil
     }}
  end

  @impl true
  def handle_cast({:start, ref, supervisor, fun, expires, reason}, %{phase: :starting} = state) do
    callback = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Process.put(Cleanup, callback)
        result = fun.()
        {now(), result}
      end)

    timer = if expires, do: Process.send_after(self(), :callback_timeout, max(0, expires - now()))
    {:noreply, %{state | ref: ref, task: task, expires: expires, timeout_reason: reason, timer: timer, phase: :running}}
  end

  def handle_cast({:cancel, reason}, %{phase: :running} = state), do: stop_worker(state, reason)
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:register_cleanup, fun}, {pid, _tag}, %{phase: :running, task: %{pid: pid}} = state) do
    {:reply, :ok, %{state | hooks: [fun | state.hooks]}}
  end

  def handle_call({:register_cleanup, _fun}, _from, state), do: {:reply, {:error, :not_in_callback}, state}

  @impl true
  def handle_info({ref, result}, %{phase: :running, task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    complete_worker(state, result)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{phase: :running, task: %{ref: ref}} = state) do
    cleanup(state, {:exit, reason}, {:exit, reason})
  end

  def handle_info(:callback_timeout, %{phase: :running} = state), do: stop_worker(state, state.timeout_reason)

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref, phase: :running} = state) do
    stop_worker(state, :owner_down)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref, phase: :starting} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{phase: :cleanup, pending: pending} = state)
      when is_map_key(pending, ref) do
    failures = cleanup_failures(reason, state.cleanup_deadline, state.cleanup_expired) ++ state.failures
    state = %{state | pending: Map.delete(pending, ref), failures: failures}
    if map_size(state.pending) == 0, do: finish(state), else: {:noreply, state}
  end

  def handle_info(:cleanup_timeout, %{phase: :cleanup} = state) do
    Enum.each(state.pending, fn {_ref, pid} -> Process.exit(pid, :kill) end)
    {:noreply, %{state | cleanup_expired: true}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp stop_worker(state, reason) do
    case Task.shutdown(state.task, :brutal_kill) do
      {:ok, result} -> complete_worker(state, result)
      _ -> cleanup(state, {:stopped, reason}, reason)
    end
  end

  defp complete_worker(state, {finished, _result} = outcome) do
    if state.expires != nil and finished >= state.expires do
      cleanup(state, {:stopped, state.timeout_reason}, state.timeout_reason)
    else
      cleanup(state, outcome, :completed)
    end
  end

  defp cleanup(state, outcome, reason) do
    cancel_timer(state.timer)
    deadline = now() + state.cleanup_timeout

    pending =
      Map.new(state.hooks, fn hook ->
        {pid, ref} =
          spawn_monitor(fn ->
            result = invoke_cleanup(hook, reason)
            exit({:cleanup_result, now(), result})
          end)

        {ref, pid}
      end)

    state = %{
      state
      | phase: :cleanup,
        task: nil,
        hooks: [],
        outcome: outcome,
        cleanup_deadline: deadline,
        pending: pending,
        timer: Process.send_after(self(), :cleanup_timeout, max(0, deadline - now()))
    }

    if map_size(pending) == 0, do: finish(state), else: {:noreply, state}
  end

  defp invoke_cleanup(hook, reason) do
    case hook.(reason) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, error} -> {:error, error}
      other -> {:error, {:invalid_result, other}}
    end
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, error -> {:error, {kind, error}}
  end

  defp cleanup_failures({:cleanup_result, finished, _result}, deadline, _expired) when finished > deadline,
    do: [:timeout]

  defp cleanup_failures({:cleanup_result, _finished, :ok}, _deadline, _expired), do: []
  defp cleanup_failures({:cleanup_result, _finished, {:error, error}}, _deadline, _expired), do: [error]
  defp cleanup_failures(:killed, _deadline, true), do: [:timeout]
  defp cleanup_failures(reason, _deadline, _expired), do: [{:exit, reason}]

  defp finish(state) do
    cancel_timer(state.timer)
    outcome = if state.failures == [], do: state.outcome, else: {:cleanup_failed, state.outcome, state.failures}
    send(state.owner, {state.ref, outcome})
    {:stop, :normal, state}
  end

  defp reply({finished, result}) when is_integer(finished), do: {:ok, result}
  defp reply({:stopped, reason}), do: {:error, reason}
  defp reply(error), do: {:error, error}

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
  defp now, do: System.monotonic_time(:millisecond)
end
