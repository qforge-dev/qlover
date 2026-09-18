defmodule Demo.Pricing do
  @moduledoc "Discounts, tax, and totals."

  @spec discount(number(), number()) :: number()
  def discount(amount, pct) do
    amount - amount * pct / 100
  end

  @spec tax(number(), number()) :: number()
  def tax(amount, rate) do
    amount + amount * rate / 100
  end

  @spec total_with_tax(number(), number(), number()) :: number()
  def total_with_tax(amount, pct, rate) do
    amount |> discount(pct) |> tax(rate)
  end

  @spec tier(number()) :: :small | :medium | :large
  def tier(amount) do
    cond do
      amount < 50 -> :small
      amount < 200 -> :medium
      true -> :large
    end
  end

  @spec free_shipping?(number()) :: boolean()
  def free_shipping?(amount) do
    if amount >= 100 do
      true
    else
      false
    end
  end
end
