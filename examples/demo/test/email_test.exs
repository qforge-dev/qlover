defmodule Demo.EmailTest do
  use ExUnit.Case, async: true

  alias Demo.Email

  test "plain addresses are valid" do
    assert Email.valid?("ada@example.com")
  end

  test "missing at-sign is invalid" do
    refute Email.valid?("not-an-email")
  end

  test "missing dot in domain is invalid" do
    refute Email.valid?("ada@localhost")
  end

  test "normalize trims and lowercases" do
    assert Email.normalize("  Ada@Example.COM  ") == "ada@example.com"
  end

  test "normalize keeps clean input" do
    assert Email.normalize("ada@example.com") == "ada@example.com"
  end

  test "domain extracts the host" do
    assert Email.domain("ada@example.com") == "example.com"
  end

  test "domain is nil without host" do
    assert Email.domain("not-an-email") == nil
  end

  test "guests are the invalid ones" do
    assert Email.guest?("nope")
    refute Email.guest?("ada@example.com")
  end
end
