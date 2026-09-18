defmodule Demo.CartTest do
  use ExUnit.Case, async: true

  alias Demo.Cart

  test "new carts start empty" do
    assert Cart.new() == []
    assert Cart.count(Cart.new()) == 0
    assert Cart.empty?(Cart.new())
  end

  test "adding items grows the cart" do
    cart = Cart.new() |> Cart.add(%{name: "apple", price: 3})
    assert Cart.count(cart) == 1
    refute Cart.empty?(cart)
  end

  test "adding several items keeps them all" do
    cart =
      Cart.new()
      |> Cart.add(%{name: "apple", price: 3})
      |> Cart.add(%{name: "pear", price: 4})

    assert Cart.count(cart) == 2
  end

  test "total sums prices" do
    cart =
      Cart.new()
      |> Cart.add(%{name: "apple", price: 3})
      |> Cart.add(%{name: "pear", price: 4})

    assert Cart.total(cart) == 7
  end

  test "empty cart totals zero" do
    assert Cart.total(Cart.new()) == 0
  end

  test "non-empty carts are not empty" do
    cart = Cart.new() |> Cart.add(%{name: "apple", price: 3})
    refute Cart.empty?(cart)
  end

  test "has? finds items by name" do
    cart = Cart.new() |> Cart.add(%{name: "apple", price: 3})
    assert Cart.has?(cart, "apple")
    refute Cart.has?(cart, "pear")
  end

  test "has? is false on empty carts" do
    refute Cart.has?(Cart.new(), "apple")
  end
end
