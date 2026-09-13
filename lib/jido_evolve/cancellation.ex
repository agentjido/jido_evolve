defmodule Jido.Evolve.Cancellation do
  @moduledoc "A cancellation token shared by a caller and a running search."

  @enforce_keys [:flag]
  defstruct [:flag]

  @opaque t :: %__MODULE__{flag: :atomics.atomics_ref()}

  @doc "Create a token. Pass it as the `:cancellation` option to a search."
  @spec new() :: t()
  def new, do: %__MODULE__{flag: :atomics.new(1, [])}

  @doc "Cancel searches that use this token. A cancelled token cannot be reset."
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{flag: flag}), do: :atomics.put(flag, 1, 1)

  @doc "Return whether cancellation was requested."
  @spec cancelled?(t() | nil) :: boolean()
  def cancelled?(nil), do: false
  def cancelled?(%__MODULE__{flag: flag}), do: :atomics.get(flag, 1) == 1
end
