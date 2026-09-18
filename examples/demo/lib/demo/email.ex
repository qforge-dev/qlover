defmodule Demo.Email do
  @moduledoc "Email validation and normalization."

  @spec valid?(String.t()) :: boolean()
  def valid?(email) do
    case String.split(email, "@") do
      [_user, domain] -> String.contains?(domain, ".")
      _other -> false
    end
  end

  @spec normalize(String.t()) :: String.t()
  def normalize(email) do
    email |> String.trim() |> String.downcase()
  end

  @spec domain(String.t()) :: String.t() | nil
  def domain(email) do
    case String.split(email, "@") do
      [_user, domain] -> domain
      _other -> nil
    end
  end

  @spec guest?(String.t()) :: boolean()
  def guest?(email) do
    if valid?(email) do
      false
    else
      true
    end
  end
end
