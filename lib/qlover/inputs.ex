defmodule Qlover.Inputs do
  @moduledoc false

  # Request-local memoization only. A test run is a mutation boundary, so its
  # caller clears this cache before validating and committing fresh evidence.
  def start, do: Process.put(__MODULE__, %{})
  def stop, do: Process.delete(__MODULE__)
  def snapshot, do: Process.get(__MODULE__, %{})
  def restore(cache), do: Process.put(__MODULE__, cache)

  def fetch(key, fun) do
    case Process.get(__MODULE__) do
      nil ->
        fun.()

      cache ->
        case Map.fetch(cache, key) do
          {:ok, value} ->
            value

          :error ->
            value = fun.()
            Process.put(__MODULE__, Map.put(Process.get(__MODULE__), key, value))
            value
        end
    end
  end
end
