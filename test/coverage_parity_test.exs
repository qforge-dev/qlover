defmodule Qlover.CoverageParityTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "attributed backend is selected only for its tested runtime family" do
    assert Qlover.Coverage.attributed_supported?("29", "1.20.2")
    refute Qlover.Coverage.attributed_supported?("28", "1.20.2")
    refute Qlover.Coverage.attributed_supported?("29", "1.18.4")
    refute Qlover.Coverage.attributed_supported?("29", "1.21.0")
  end

  test "source maps follow the current worktree rather than a copied BEAM's source path" do
    expected = Path.expand("lib/qlover.ex")

    assert Qlover.Coverage.Evidence.source_path("/some-other-worktree/lib/qlover.ex") ==
             expected
  end

  test "missing, corrupt and incompatible attributed reports are not reusable", %{tmp_dir: dir} do
    path = Path.join(dir, "report")
    assert Qlover.Coverage.read_report(path) == nil
    File.write!(path, "not an Erlang term")
    assert Qlover.Coverage.read_report(path) == nil

    File.write!(
      path,
      :erlang.term_to_binary(%{
        vsn: 2,
        otp: "old",
        elixir: System.version(),
        backend: :sys_coverage,
        complete: true,
        beams: %{},
        inventory: %{},
        hits: %{}
      })
    )

    assert Qlover.Coverage.read_report(path) == nil
  end

  test "OTP executable lines and runtime hits agree on branches, guards, comprehensions and exceptions",
       %{
         tmp_dir: dir
       } do
    source = Path.join(dir, "parity.ex")
    beams = Path.join(dir, "ebin")
    File.mkdir_p!(beams)

    File.write!(source, """
    defmodule QloverParity do
      def branch(x) do
        case x do
          :left -> :one
          :right -> :two
        end
      end

      def guarded(x) when is_integer(x), do: x + 1
      def guarded(_), do: :other

      def values(xs) do
        for x <- xs, rem(x, 2) == 0, do: x * 2
      end

      def rescued(x) do
        try do
          div(10, x)
        rescue
          ArithmeticError -> :bad
        end
      end
    end
    """)

    native = run_backend!(source, beams, :native)
    attributed = run_backend!(source, beams, :attributed)
    assert attributed == native
  end

  test "pinned receive variables survive instrumentation with native coverage parity", %{
    tmp_dir: dir
  } do
    source = Path.join(dir, "receive.ex")
    beams = Path.join(dir, "ebin")
    File.mkdir_p!(beams)

    File.write!(source, """
    defmodule QloverReceiveParity do
      def await(ref) do
        receive do
          {^ref, :left} -> :left
          {^ref, :right} -> :right
        end
      end
    end
    """)

    calls = """
    ref = make_ref()
    send(self(), {ref, :left})
    :left = module.await(ref)
    """

    native = run_backend!(source, beams, :native, calls)
    attributed = run_backend!(source, beams, :attributed, calls)
    assert attributed == native
    {all, hits} = attributed
    assert hits != []
    assert length(hits) < length(all)
  end

  test "instrumentation cache repairs corruption and invalidates line and code edits", %{
    tmp_dir: dir
  } do
    source = Path.join(dir, "cached.ex")
    beams = Path.join(dir, "ebin")
    File.mkdir_p!(beams)
    File.write!(source, "defmodule QloverCacheParity do\n  def value, do: :before\nend\n")

    {output, code} =
      System.cmd(
        "elixir",
        ["-e", cache_script(), "--", source, beams, Mix.Project.compile_path()],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "CACHE_OK"
  end

  defp cache_script do
    """
    [source, beams, qlover] = System.argv()
    Code.prepend_path(qlover)
    Code.compiler_options(debug_info: true, ignore_module_conflict: true)
    compile = fn ->
      [{module, binary}] = Code.compile_file(source)
      File.write!(Path.join(beams, Atom.to_string(module) <> ".beam"), binary)
    end
    compile.()
    {first, %{instrument_cache_misses: 1}} = Qlover.Coverage.Instrumenter.instrument_with_stats!(beams, [])
    {^first, %{instrument_cache_hits: 1}} = Qlover.Coverage.Instrumenter.instrument_with_stats!(beams, [])
    [cache] = Path.wildcard(Path.join([Path.dirname(beams), ".mix", "qlover_instrumented", "*"]))
    File.write!(cache, "corrupt")
    {^first, %{instrument_cache_misses: 1}} = Qlover.Coverage.Instrumenter.instrument_with_stats!(beams, [])
    File.write!(source, "\\n" <> String.replace(File.read!(source), ":before", ":after"))
    compile.()
    {changed, %{instrument_cache_misses: 1}} = Qlover.Coverage.Instrumenter.instrument_with_stats!(beams, [])
    if changed == first, do: raise("line shift reused old probes")
    :ets.new(:qlover_attributed_hits, [:named_table, :public, :set])
    :after = QloverCacheParity.value()
    {^changed, %{instrument_cache_hits: 1}} = Qlover.Coverage.Instrumenter.instrument_with_stats!(beams, [])
    :after = QloverCacheParity.value()
    IO.puts("CACHE_OK")
    """
  end

  defp run_backend!(
         source,
         beams,
         backend,
         calls \\ """
         module.branch(:left)
         module.guarded(:x)
         module.values([1, 2, 3])
         module.rescued(0)
         """
       ) do
    script = """
    [source, beams, backend, qlover] = System.argv()
    Code.prepend_path(qlover)
    Code.compiler_options(debug_info: true)
    [{module, binary}] = Code.compile_file(source)
    beam = Path.join(beams, Atom.to_string(module) <> ".beam")
    File.write!(beam, binary)

    inventory =
      if backend == "native" do
        {:ok, _} = :cover.start()
        {:ok, ^module} = :cover.compile_beam(String.to_charlist(beam))
        nil
      else
        Code.ensure_loaded!(ExUnit.Runner)
        offline = Qlover.Coverage.Instrumenter.inventory!(beams, [Path.basename(beam)], [])
        inventory = Qlover.Coverage.Instrumenter.instrument!(beams, [])
        {cached, stats} = Qlover.Coverage.Instrumenter.instrument_with_stats!(beams, [])
        if cached != inventory, do: raise("cached inventory differs from fresh probes")
        if stats.instrument_cache_hits != 1 or stats.instrument_cache_misses != 0,
          do: raise("unchanged module was recompiled")
        if offline != inventory, do: raise("offline inventory differs from runtime probes")
        Qlover.Coverage.Runtime.start!()
        inventory
      end

    #{calls}

    result =
      if backend == "native" do
        {:ok, entries} = :cover.analyse(module, :coverage, :line)
        all = for {{^module, line}, _} <- entries, line > 0, do: line
        hits = for {{^module, line}, {count, _}} <- entries, line > 0, count > 0, do: line
        {Enum.sort(Enum.uniq(all)), Enum.sort(Enum.uniq(hits))}
      else
        %{probes: probes, lines: all} = inventory[Atom.to_string(module)]
        hits = for {{pid, ^module, id}} <- :ets.tab2list(:qlover_attributed_hits),
                   pid == self(),
                   line = probes[id], line > 0, do: line
        {all, Enum.sort(Enum.uniq(hits))}
      end

    IO.puts("PARITY:" <> Base.encode64(:erlang.term_to_binary(result)))
    """

    {output, code} =
      System.cmd(
        "elixir",
        ["-e", script, "--", source, beams, to_string(backend), Mix.Project.compile_path()],
        stderr_to_stdout: true
      )

    assert code == 0, output
    [_, encoded] = Regex.run(~r/PARITY:([A-Za-z0-9+\/=]+)/, output) || flunk(output)
    encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
  end
end
