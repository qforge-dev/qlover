defmodule Demo.ShippingTest do
  use ExUnit.Case, async: true

  alias Demo.Shipping

  test "local zone adds the small fee" do
    assert Shipping.cost(2, :local) == 6
  end

  test "national zone adds the medium fee" do
    assert Shipping.cost(2, :national) == 12
  end

  test "world zone adds the large fee" do
    assert Shipping.cost(2, :world) == 24
  end

  test "weightless parcels only pay the fee" do
    assert Shipping.cost(0, :local) == 2
  end

  test "base scales with weight" do
    assert Shipping.base(3) == 6
  end

  test "base is zero without weight" do
    assert Shipping.base(0) == 0
  end

  test "express speed is express" do
    assert Shipping.express?(:express)
  end

  test "anything else is standard" do
    refute Shipping.express?(:standard)
  end
end
