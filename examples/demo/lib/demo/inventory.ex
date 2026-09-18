defmodule Demo.Inventory do
  @moduledoc "Stock levels: check, reserve, release."

  @type stock :: %{required(String.t()) => non_neg_integer()}

  @spec in_stock?(stock(), String.t(), non_neg_integer()) :: boolean()
  def in_stock?(stock, name, qty) do
    Map.get(stock, name, 0) >= qty
  end

  @spec reserve(stock(), String.t(), non_neg_integer()) ::
          {:ok, stock()} | {:error, :out_of_stock}
  def reserve(stock, name, qty) do
    if in_stock?(stock, name, qty) do
      {:ok, Map.update!(stock, name, &(&1 - qty))}
    else
      {:error, :out_of_stock}
    end
  end

  @spec release(stock(), String.t(), non_neg_integer()) :: stock()
  def release(stock, name, qty) do
    Map.update(stock, name, qty, &(&1 + qty))
  end

  @spec status(stock(), String.t()) :: :missing | :low | :ok
  def status(stock, name) do
    case Map.get(stock, name, 0) do
      0 -> :missing
      n when n < 5 -> :low
      _n -> :ok
    end
  end
end
