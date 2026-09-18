defmodule Demo.Cart do
  @moduledoc "Shopping cart: add items, count them, total the price."

  @type item :: %{name: String.t(), price: number()}
  @type t :: [item()]

  @spec new() :: t()
  def new, do: []

  @spec add(t(), item()) :: t()
  def add(cart, item), do: [item | cart]

  @spec count(t()) :: non_neg_integer()
  def count(cart), do: length(cart)

  @spec total(t()) :: number()
  def total(cart) do
    Enum.reduce(cart, 0, fn item, acc -> acc + item.price end)
  end

  @spec empty?(t()) :: boolean()
  def empty?(cart) do
    case cart do
      [] -> true
      _items -> false
    end
  end

  @spec has?(t(), String.t()) :: boolean()
  def has?(cart, name) do
    Enum.any?(cart, fn item -> item.name == name end)
  end
end
