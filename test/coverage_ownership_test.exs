defmodule Qlover.CoverageOwnershipTest do
  use ExUnit.Case, async: false

  test "descendants retain ownership when their spawn traces arrive before their ancestors" do
    run!("execution", "reverse")
    run!("execution", "forward")
  end

  test "descendants retain the loading file after its loading context ends" do
    run!("loading", "reverse")
    run!("loading", "forward")
  end

  defp run!(context, order) do
    {output, code} =
      System.cmd("elixir", ["-pa", Mix.Project.compile_path(), "-e", script(), context, order],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "OWNERSHIP_OK"
  end

  defp script do
    """
    [context, order] = System.argv()
    Code.ensure_loaded!(ExUnit.Runner)
    defmodule OwnershipFixture do
      def value, do: :ok
    end
    file = OwnershipFixture.module_info(:compile)[:source] |> to_string() |> Path.relative_to_cwd()
    runtime = {session, tracer, _} = Qlover.Coverage.Runtime.start!([file])
    :trace.process(session, :all, false, [:all])
    worker = fn hit? ->
      {pid, ref} = spawn_monitor(fn ->
        if hit?, do: Qlover.Coverage.Runtime.hit(OwnershipFixture, 1)
      end)
      receive do {:DOWN, ^ref, :process, ^pid, :normal} -> pid end
    end
    parent = worker.(false)
    child = worker.(false)
    grandchild = worker.(true)
    if context == "loading" do
      send(tracer, {:trace, parent, :call, {Qlover.Coverage.Runtime, :enter, [Path.expand(file)]}})
    else
      send(tracer, {:trace, parent, :call,
        {ExUnit.Runner, :exec_test_setup, [%ExUnit.Test{module: OwnershipFixture}, %{}]}})
    end
    events = [
      {:trace, parent, :spawn, child, {OwnershipFixture, :value, []}},
      {:trace, child, :spawn, grandchild, {OwnershipFixture, :value, []}}
    ]
    for event <- if(order == "reverse", do: Enum.reverse(events), else: events), do: send(tracer, event)
    if context == "loading" do
      send(tracer, {:trace, parent, :call, {Qlover.Coverage.Runtime, :leave, []}})
    end
    # Only the deepest descendant's unique probe may satisfy this line.
    inventory = %{"Elixir.OwnershipFixture" => %{probes: %{1 => 7}}}
    {hits, %{}, stats} = Qlover.Coverage.Runtime.finish!(runtime, inventory)
    %{^file => %{"Elixir.OwnershipFixture" => [7]}} = hits
    0 = stats.unknown_hit_records
    IO.puts("OWNERSHIP_OK")
    """
  end
end
