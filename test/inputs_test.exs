defmodule Qlover.InputsTest do
  use ExUnit.Case, async: true

  test "memoization is scoped to a phase and never survives its boundary" do
    count = fn -> Process.put(:reads, Process.get(:reads, 0) + 1) end
    Qlover.Inputs.fetch(:a, count)
    Qlover.Inputs.fetch(:a, count)
    assert Process.get(:reads) == 2
    Qlover.Inputs.start()
    Qlover.Inputs.fetch(:a, count)
    Qlover.Inputs.fetch(:a, count)
    assert Process.get(:reads) == 3
    Qlover.Inputs.start()
    Qlover.Inputs.fetch(:a, count)
    assert Process.get(:reads) == 4
    Qlover.Inputs.stop()
    Qlover.Inputs.fetch(:a, count)
    assert Process.get(:reads) == 5
  end
end
