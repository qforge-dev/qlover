defmodule Demo.Receipt do
  @moduledoc "Receipts combine the cart with pricing."

  alias Demo.Cart
  alias Demo.Pricing

  @spec build(Cart.t(), number(), number()) :: map()
  def build(cart, pct, rate) do
    subtotal = Cart.total(cart)

    %{
      items: Cart.count(cart),
      subtotal: subtotal,
      total: Pricing.total_with_tax(subtotal, pct, rate)
    }
  end

  @spec summary(map()) :: String.t()
  def summary(receipt) do
    if receipt.items == 0 do
      "empty"
    else
      "#{receipt.items} items: #{receipt.total}"
    end
  end
end
