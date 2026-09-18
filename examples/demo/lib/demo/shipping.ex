defmodule Demo.Shipping do
  @moduledoc "Shipping cost by weight and zone."

  @spec cost(number(), :local | :national | :world) :: number()
  def cost(weight, zone) do
    case zone do
      :local -> base(weight) + 2
      :national -> base(weight) + 8
      :world -> base(weight) + 20
    end
  end

  @spec base(number()) :: number()
  def base(weight) do
    if weight <= 0 do
      0
    else
      weight * 2
    end
  end

  @spec express?(atom()) :: boolean()
  def express?(speed) do
    case speed do
      :express -> true
      _other -> false
    end
  end
end
