defmodule Demo.ReceiptTest do
  use ExUnit.Case, async: true

  alias Demo.Cart
  alias Demo.Receipt

  test "receipt totals the cart" do
    cart = Cart.new() |> Cart.add(%{name: "apple", price: 50})
    receipt = Receipt.build(cart, 0, 0)
    assert receipt.items == 1
    assert receipt.subtotal == 50
  end

  test "receipt applies discount and tax" do
    cart = Cart.new() |> Cart.add(%{name: "apple", price: 100})
    receipt = Receipt.build(cart, 10, 10)
    assert receipt.total == 99.0
  end

  test "empty carts get empty receipts" do
    receipt = Receipt.build(Cart.new(), 0, 0)
    assert receipt.items == 0
    assert receipt.subtotal == 0
  end

  test "summary names the item count" do
    cart = Cart.new() |> Cart.add(%{name: "apple", price: 50})
    assert Receipt.summary(Receipt.build(cart, 0, 0)) == "1 items: 50.0"
  end

  test "summary calls empty carts empty" do
    assert Receipt.summary(Receipt.build(Cart.new(), 0, 0)) == "empty"
  end

  test "multi-item carts add up" do
    cart =
      Cart.new()
      |> Cart.add(%{name: "apple", price: 30})
      |> Cart.add(%{name: "pear", price: 20})

    assert Receipt.build(cart, 0, 0).subtotal == 50
  end

  test "discounts flow through receipts" do
    cart = Cart.new() |> Cart.add(%{name: "apple", price: 200})
    assert Receipt.build(cart, 50, 0).total == 100.0
  end

  test "tax flows through receipts" do
    cart = Cart.new() |> Cart.add(%{name: "apple", price: 100})
    assert Receipt.build(cart, 0, 23) == %{items: 1, subtotal: 100, total: 123.0}
  end
end
