defmodule Qlover.TestTaskTest do
  @moduledoc """
  Single-command orchestration: stale vs full selection, arg forwarding,
  and fail-closed test runs.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Test.Qlover, as: TestQlover
  alias Mix.Tasks.Qlover

  @moduletag :tmp_dir

  test "split_args! passes test args through untouched" do
    assert {[], ["test/foo_test.exs", "--seed", "0"]} =
             TestQlover.split_args!(["test/foo_test.exs", "--seed", "0"])

    assert {[], []} = TestQlover.split_args!([])
  end

  test "split_args! extracts qlover path flags" do
    {flags, rest} =
      TestQlover.split_args!(["--baseline", "b", "test/a.exs", "--export=custom.coverdata"])

    assert flags[:baseline] == "b"
    assert flags[:export] == "custom.coverdata"
    assert rest == ["test/a.exs"]

    {eq_flags, eq_rest} = TestQlover.split_args!(["--baseline=b", "--export", "e"])
    assert eq_flags[:baseline] == "b"
    assert eq_flags[:export] == "e"
    assert eq_rest == []

    {exp_flags, exp_rest} =
      TestQlover.split_args!(["--expansion-export", "x", "--expansion-export=y"])

    assert exp_flags[:expansion_export] == "y"
    assert exp_rest == []
  end

  test "split_args! rejects flags managed by the task" do
    for flag <- [
          "--stale",
          "--no-stale",
          "--cover",
          "--no-cover",
          "--export-coverage",
          "--failed",
          "--partitions",
          "--dry-run",
          "--no-compile"
        ] do
      assert_raise Mix.Error, ~r/manages #{Regex.escape(flag)}/, fn ->
        TestQlover.split_args!(["test/a.exs", flag])
      end
    end

    assert_raise Mix.Error, ~r/manages --export-coverage/, fn ->
      TestQlover.split_args!(["--export-coverage=other"])
    end

    assert_raise Mix.Error, ~r/manages --partitions/, fn ->
      TestQlover.split_args!(["--partitions=2"])
    end
  end

  test "single-arity entrypoint delegates to run/2" do
    assert_raise Mix.Error, ~r/manages --stale/, fn -> TestQlover.run(["--stale"]) end
  end

  test "refuses to run outside the test environment", %{tmp_dir: dir} do
    opts = task_opts(dir)
    Mix.env(:dev)

    try do
      assert_raise Mix.Error, ~r/test environment/, fn -> TestQlover.run([], opts) end
    after
      Mix.env(:test)
    end
  end

  test "unchanged tree gates without running tests", %{tmp_dir: dir} do
    compile_beam!(dir, "Same", "  def a, do: :ok\n")
    opts = task_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts)
    baseline_bytes = File.read!(opts[:baseline])

    runner = fn cmd ->
      send(self(), {:test_cmd, cmd})
      0
    end

    assert :ok = TestQlover.run(["test/foo_test.exs"], Keyword.put(opts, :test_runner, runner))

    # Nothing changed, so there is nothing to run — not even an
    # explicitly requested file. User args only ever widen the run.
    refute_received {:test_cmd, _}

    assert File.read!(opts[:baseline]) == baseline_bytes
    refute File.exists?(opts[:export_path])
  end

  test "focused run failure aborts before gating", %{tmp_dir: dir} do
    compile_beam!(dir, "Same", "  def a, do: :ok\n")
    opts = task_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts)
    baseline_bytes = File.read!(opts[:baseline])

    rel = write_test!(dir, "added_test.exs", "# brand new\n")

    runner = fn cmd ->
      send(self(), {:test_cmd, cmd})
      2
    end

    assert_raise Mix.Error, ~r/failed.*exit 2/, fn ->
      TestQlover.run([], Keyword.put(opts, :test_runner, runner))
    end

    assert_received {:test_cmd,
                     ["test", "--no-stale", "--cover", "--export-coverage", "fresh", ^rel]}

    assert File.read!(opts[:baseline]) == baseline_bytes
  end

  test "changed beams without runnable referencers fail closed", %{tmp_dir: dir} do
    compile_beam!(dir, "Changed", "  def a, do: :ok\n")
    opts = task_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts)
    compile_beam!(dir, "ChangedV2", "  def a, do: :ok\n  def b, do: :ok\n")

    me = self()

    runner = fn cmd ->
      send(me, {:test_cmd, cmd})
      0
    end

    # No test file references the changed beam, so nothing runs and the
    # gate fails for lack of fresh proof instead of guessing.
    assert_raise Mix.Error, ~r/cannot import/, fn ->
      TestQlover.run([], Keyword.put(opts, :test_runner, runner))
    end

    refute_received {:test_cmd, _}
  end

  test "explicit selection runs referencers once, never stale", %{tmp_dir: dir} do
    compile_beam!(dir, "Pass", "  def a, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "pass_test.exs", "# v1\n")
    old_sha = file_sha!(dir, rel)

    {module, _beam} = compile_beam!(dir, "PassRef", "  def a, do: :ok\n  def b, do: :ok\n")
    mod_string = Atom.to_string(module)

    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{rel => %{sha: old_sha, modules: [mod_string]}},
      librefs: %{}
    })

    {^module, beam} = compile_beam!(dir, "PassRef", "  def a, do: :okay\n  def b, do: :ok\n")
    export_path = opts[:export_path]
    me = self()

    runner = fn cmd ->
      send(me, {:test_cmd, cmd})
      fresh_export!(beam, export_path, module, [:a, :b])
      0
    end

    assert :ok = TestQlover.run([], Keyword.put(opts, :test_runner, runner))

    assert_received {:test_cmd, cmd}
    assert cmd == ["test", "--no-stale", "--cover", "--export-coverage", "fresh", rel]
    refute_received {:test_cmd, _}

    assert File.regular?(Path.join(opts[:output], "#{module}.html"))
    refute File.exists?(opts[:export_path])
  end

  test "first run takes the full path and snapshots", %{tmp_dir: dir} do
    compile_beam!(dir, "First", "  def a, do: :ok\n")
    opts = task_opts(dir)
    refute File.exists?(opts[:baseline])

    runner = fn cmd ->
      send(self(), {:test_cmd, cmd})
      0
    end

    assert :ok = TestQlover.run(["--seed", "0"], Keyword.put(opts, :test_runner, runner))

    assert_received {:test_cmd, ["test", "--no-stale", "--cover", "--seed", "0"]}
    assert File.regular?(opts[:baseline])
    assert :ok = Qlover.run(["--eligible"], opts)
  end

  test "gate-input drift falls back to full and re-baselines", %{tmp_dir: dir} do
    compile_beam!(dir, "Drift", "  def a, do: :ok\n")
    opts = task_opts(dir)
    gate_file = Path.join([dir, "gate", "input.txt"])
    File.write!(gate_file, "v1")

    assert :ok = Qlover.run(["--write-baseline"], opts)
    File.write!(gate_file, "v2")

    assert :ok = TestQlover.run([], Keyword.put(opts, :test_runner, fn _cmd -> 0 end))
    assert %{gate: gate} = :erlang.binary_to_term(File.read!(opts[:baseline]))
    assert gate == Qlover.gate_hash(opts[:gate_paths], opts[:project_root])
  end

  test "full run failure never writes a baseline", %{tmp_dir: dir} do
    compile_beam!(dir, "First", "  def a, do: :ok\n")
    opts = task_opts(dir)

    assert_raise Mix.Error, ~r/failed.*exit 1/, fn ->
      TestQlover.run([], Keyword.put(opts, :test_runner, fn _cmd -> 1 end))
    end

    refute File.exists?(opts[:baseline])
  end

  test "custom export paths derive the export name", %{tmp_dir: dir} do
    {mod, beam} = compile_beam!(dir, "Same", "  def a, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "same_test.exs", "# v1\n")
    old_sha = file_sha!(dir, rel)

    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{rel => %{sha: old_sha, modules: ["Elixir.QloverFixSame"]}},
      librefs: %{}
    })

    write_test!(dir, "same_test.exs", "# v2\n")

    custom = Path.join(dir, "custom.coverdata")
    opts = Keyword.put(opts, :export_path, custom)

    runner = fn cmd ->
      send(self(), {:test_cmd, cmd})
      fresh_export!(beam, custom, mod, [:a])
      0
    end

    # The Same beam is unchanged but the edited test re-proves it, so the
    # selection still runs the changed file once under the custom name.
    assert :ok = TestQlover.run(["--export", custom], Keyword.put(opts, :test_runner, runner))

    assert_received {:test_cmd, cmd}
    assert ["test", "--no-stale", "--cover", "--export-coverage", "custom", ^rel] = cmd
    refute_received {:test_cmd, _}
    refute File.exists?(custom)
  end

  test "default runner shells out and reports exit codes" do
    assert 0 = TestQlover.default_runner(["--version"])
    assert 0 != TestQlover.default_runner(["no_such_task_qlover_xyz"])
  end

  test "invalid baselines take the full path", %{tmp_dir: dir} do
    compile_beam!(dir, "First", "  def a, do: :ok\n")
    opts = task_opts(dir)
    File.write!(opts[:baseline], "garbage")

    runner = fn cmd ->
      send(self(), {:test_cmd, cmd})
      0
    end

    assert :ok = TestQlover.run([], Keyword.put(opts, :test_runner, runner))

    assert_received {:test_cmd, ["test", "--no-stale", "--cover"]}
    assert %{vsn: 4} = :erlang.binary_to_term(File.read!(opts[:baseline]))
  end

  test "focused run covers stale and expansion in one call", %{tmp_dir: dir} do
    {mod, beam} = compile_beam!(dir, "OrchM", "  def a, do: :ok\n  def b, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "orch_test.exs", "# v1\n")
    old_sha = file_sha!(dir, rel)

    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{rel => %{sha: old_sha, modules: [Atom.to_string(mod)]}},
      librefs: %{}
    })

    write_test!(dir, "orch_test.exs", "# v2\n")
    me = self()

    runner = fn cmd ->
      send(me, {:test_cmd, cmd})
      fresh_export!(beam, opts[:export_path], mod, [:a, :b])
      0
    end

    assert :ok = TestQlover.run([], Keyword.put(opts, :test_runner, runner))

    assert_received {:test_cmd, cmd}
    assert cmd == ["test", "--no-stale", "--cover", "--export-coverage", "fresh", rel]
    refute_received {:test_cmd, _}
    refute File.exists?(opts[:export_path])
    refute File.exists?(opts[:expansion_export_path])
    assert File.regular?(Path.join(opts[:output], "#{mod}.html"))

    snapshot = :erlang.binary_to_term(File.read!(opts[:baseline]))
    assert snapshot.tests[rel].sha == file_sha!(dir, rel)
  end

  test "user file args widen the selection", %{tmp_dir: dir} do
    {mod, beam} = compile_beam!(dir, "WideM", "  def a, do: :ok\n  def b, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "wide_test.exs", "# v1\n")
    old_sha = file_sha!(dir, rel)

    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{rel => %{sha: old_sha, modules: [Atom.to_string(mod)]}},
      librefs: %{}
    })

    write_test!(dir, "wide_test.exs", "# v2\n")
    me = self()

    runner = fn cmd ->
      send(me, {:test_cmd, cmd})
      2
    end

    assert_raise Mix.Error, ~r/failed.*exit 2/, fn ->
      TestQlover.run(["test/extra_test.exs"], Keyword.put(opts, :test_runner, runner))
    end

    assert_received {:test_cmd, cmd}

    assert cmd == [
             "test",
             "--no-stale",
             "--cover",
             "--export-coverage",
             "fresh",
             rel,
             "test/extra_test.exs"
           ]
  end

  test "attribution path falls back to full on fixture changes", %{tmp_dir: dir} do
    compile_beam!(dir, "OrchF", "  def a, do: :ok\n")
    opts = task_opts(dir)
    write_baseline_v2(opts, %{})

    File.write!(Path.join([dir, "t", "data.json"]), ~s({"v": 1}))

    runner = fn cmd ->
      send(self(), {:test_cmd, cmd})
      0
    end

    assert :ok = TestQlover.run([], Keyword.put(opts, :test_runner, runner))
    assert_received {:test_cmd, ["test", "--no-stale", "--cover"]}

    assert :erlang.binary_to_term(File.read!(opts[:baseline])).tests
           |> Map.has_key?("t/data.json")
  end

  test "attribution path falls back to full without references", %{tmp_dir: dir} do
    compile_beam!(dir, "OrchU", "  def a, do: :ok\n")
    opts = task_opts(dir)
    write_test!(dir, "orchu_test.exs", "# v1\n")

    assert :ok = Qlover.run(["--write-baseline"], opts)

    write_test!(dir, "orchu_test.exs", "# v2\n")

    runner = fn cmd ->
      send(self(), {:test_cmd, cmd})
      0
    end

    assert :ok = TestQlover.run([], Keyword.put(opts, :test_runner, runner))
    assert_received {:test_cmd, ["test", "--no-stale", "--cover"]}
  end

  test "explicit selection skips compiled support files", %{tmp_dir: dir} do
    {mod, beam} = compile_beam!(dir, "SupM", "  def a, do: :ok\n  def b, do: :ok\n")
    opts = task_opts(dir)
    opts = Keyword.put(opts, :elixirc_paths, [Path.join(dir, "sup")])
    File.mkdir_p!(Path.join(dir, "sup"))
    File.write!(Path.join(dir, "sup/help.ex"), "# support\n")
    rel = write_test!(dir, "sup_test.exs", "# v1\n")
    old_sha = file_sha!(dir, rel)

    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{
        rel => %{sha: old_sha, modules: [Atom.to_string(mod)]},
        "sup/help.ex" => %{sha: file_sha!(dir, "sup/help.ex"), modules: [Atom.to_string(mod)]}
      },
      librefs: %{}
    })

    write_test!(dir, "sup_test.exs", "# v2\n")
    me = self()

    runner = fn cmd ->
      send(me, {:test_cmd, cmd})
      fresh_export!(beam, opts[:export_path], mod, [:a, :b])
      0
    end

    assert :ok = TestQlover.run([], Keyword.put(opts, :test_runner, runner))

    assert_received {:test_cmd, cmd}
    assert cmd == ["test", "--no-stale", "--cover", "--export-coverage", "fresh", rel]
    refute_received {:test_cmd, _}
    refute File.exists?(opts[:export_path])
    refute File.exists?(opts[:expansion_export_path])
  end

  test "deleted tests with no runnable referencers fail without running", %{tmp_dir: dir} do
    {mod, _beam} = compile_beam!(dir, "OrchD", "  def a, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "orchd_test.exs", "# doomed\n")
    old_sha = file_sha!(dir, rel)

    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{rel => %{sha: old_sha, modules: [Atom.to_string(mod)]}},
      librefs: %{}
    })

    File.rm!(Path.join(dir, rel))

    me = self()

    runner = fn cmd ->
      send(me, {:test_cmd, cmd})
      0
    end

    assert_raise Mix.Error, ~r/cannot import/, fn ->
      TestQlover.run([], Keyword.put(opts, :test_runner, runner))
    end

    refute_received {:test_cmd, _}
  end

  test "explicit run failure aborts before gating", %{tmp_dir: dir} do
    {mod, beam} = compile_beam!(dir, "OrchX", "  def a, do: :ok\n  def b, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "orchx_test.exs", "# v1\n")
    old_sha = file_sha!(dir, rel)

    baseline_before =
      write_baseline_v2(opts, %{rel => %{sha: old_sha, modules: [Atom.to_string(mod)]}})

    write_test!(dir, "orchx_test.exs", "# v2\n")
    me = self()

    runner = fn cmd ->
      send(me, {:test_cmd, cmd})
      2
    end

    assert_raise Mix.Error, ~r/failed.*exit 2/, fn ->
      TestQlover.run([], Keyword.put(opts, :test_runner, runner))
    end

    assert_received {:test_cmd, _}
    refute_received {:test_cmd, _}
    assert File.read!(opts[:baseline]) == baseline_before
    _ = beam
  end

  defp write_test!(dir, name, body) do
    rel = "t/#{name}"
    File.write!(Path.join(dir, rel), body)
    rel
  end

  defp file_sha!(dir, rel) do
    :crypto.hash(:sha256, File.read!(Path.join(dir, rel))) |> Base.encode16(case: :lower)
  end

  defp write_baseline_map!(opts, map) do
    File.write!(opts[:baseline], :erlang.term_to_binary(map, [:compressed]))
  end

  defp write_baseline_v2(opts, tests) do
    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: tests,
      librefs: %{}
    })

    File.read!(opts[:baseline])
  end

  defp task_opts(dir) do
    beams = Path.join(dir, "ebin")
    gate_dir = Path.join(dir, "gate")
    File.mkdir_p!(beams)
    File.mkdir_p!(gate_dir)
    File.mkdir_p!(Path.join(dir, "t"))

    [
      baseline: Path.join(dir, "baseline"),
      export_path: Path.join(dir, "fresh.coverdata"),
      expansion_export_path: Path.join(dir, "expansion.coverdata"),
      compile_path: beams,
      gate_paths: [gate_dir],
      test_paths: ["t"],
      project_root: dir,
      refs_dir: Path.join(dir, "refs"),
      cache_dir: Path.join(dir, "cache"),
      output: Path.join(dir, "html")
    ]
  end

  defp compile_beam!(dir, tag, body) do
    module = String.to_atom("Elixir.QloverFix#{tag}")
    source_path = Path.join(dir, "#{tag}.ex")
    File.write!(source_path, "defmodule #{module} do\n#{body}end\n")
    previous = Code.compiler_options(debug_info: true, docs: false)

    try do
      {:ok, [module], _diagnostics} =
        Kernel.ParallelCompiler.compile_to_path(
          [source_path],
          Path.join(dir, "ebin"),
          return_diagnostics: true
        )

      {module, Path.join(dir, "ebin/#{module}.beam")}
    after
      Code.compiler_options(previous)
    end
  end

  defp fresh_export!(beam, export_path, module, funs) do
    Mix.ensure_application!(:tools)
    _cover = :cover.start()
    {:ok, ^module} = :cover.compile_beam(String.to_charlist(beam))
    Enum.each(funs, &apply(module, &1, []))
    :ok = :cover.export(String.to_charlist(export_path), module)
    :ok
  end
end
