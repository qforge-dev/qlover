defmodule Demo.InventoryTest do
  use ExUnit.Case, async: true

  alias Demo.Inventory

  test "stock check passes when enough units exist" do
    assert Inventory.in_stock?(%{"apple" => 5}, "apple", 3)
  end

  test "stock check fails when short" do
    refute Inventory.in_stock?(%{"apple" => 1}, "apple", 3)
  end

  test "missing products are out of stock" do
    refute Inventory.in_stock?(%{}, "apple", 1)
  end

  test "reserving decrements the stock" do
    assert Inventory.reserve(%{"apple" => 5}, "apple", 2) == {:ok, %{"apple" => 3}}
  end

  test "reserving too much fails" do
    assert Inventory.reserve(%{"apple" => 1}, "apple", 2) == {:error, :out_of_stock}
  end

  test "releasing adds units back" do
    assert Inventory.release(%{"apple" => 3}, "apple", 2) == %{"apple" => 5}
  end

  test "releasing unknown products seeds them" do
    assert Inventory.release(%{}, "pear", 2) == %{"pear" => 2}
  end

  test "status reports missing, low, ok" do
    assert Inventory.status(%{}, "apple") == :missing
    assert Inventory.status(%{"apple" => 2}, "apple") == :low
    assert Inventory.status(%{"apple" => 9}, "apple") == :ok
  end
end
