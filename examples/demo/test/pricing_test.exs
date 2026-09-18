defmodule Demo.PricingTest do
  use ExUnit.Case, async: true

  alias Demo.Pricing

  test "discount cuts the percentage" do
    assert Pricing.discount(100, 10) == 90.0
  end

  test "zero discount keeps the amount" do
    assert Pricing.discount(100, 0) == 100.0
  end

  test "tax adds the rate" do
    assert Pricing.tax(100, 23) == 123.0
  end

  test "zero tax keeps the amount" do
    assert Pricing.tax(100, 0) == 100.0
  end

  test "total chains discount then tax" do
    assert Pricing.total_with_tax(100, 10, 10) == 99.0
  end

  test "tiers split small, medium, large" do
    assert Pricing.tier(10) == :small
    assert Pricing.tier(100) == :medium
    assert Pricing.tier(500) == :large
  end

  test "big orders ship free" do
    assert Pricing.free_shipping?(150)
  end

  test "small orders pay shipping" do
    refute Pricing.free_shipping?(20)
  end
end
