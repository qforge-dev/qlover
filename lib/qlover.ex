defmodule Qlover do
  @moduledoc """
  Incremental line-coverage gating for stale ExUnit runs.

  `mix test --cover` only measures the tests that actually ran, so combining
  it with `mix test --stale` reports partial numbers. Qlover closes the gap:
  it records a baseline from the last green full run and lets a later stale
  run satisfy the coverage gate for everything the stale subset did not need
  to re-execute. See `Mix.Tasks.Qlover` for the mechanism and `README.md`
  for the background.
  """
end
