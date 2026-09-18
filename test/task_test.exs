defmodule Qlover.TaskTest do
  @moduledoc """
  Baseline snapshots, eligibility checks, and stale-run gating.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Qlover

  @moduletag :tmp_dir

  test "writes a baseline that reports eligible", %{tmp_dir: dir} do
    compile_beam!(dir, "Eligible", "  def a, do: :ok\n")
    opts = task_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts)
    assert File.regular?(opts[:baseline])
    assert :ok = Qlover.run(["--eligible"], opts)
  end

  test "rejects unexpected arguments", %{tmp_dir: dir} do
    opts = task_opts(dir)

    assert_raise Mix.Error, fn -> Qlover.run(["unexpected"], opts) end
    assert_raise OptionParser.ParseError, fn -> Qlover.run(["--unknown"], opts) end
  end

  test "single-arity entrypoint delegates to run/2" do
    assert_raise Mix.Error, ~r/usage/, fn -> Qlover.run(["unexpected"]) end
  end

  test "refuses to run outside the test environment", %{tmp_dir: dir} do
    opts = task_opts(dir)
    Mix.env(:dev)

    try do
      assert_raise Mix.Error, ~r/test environment/, fn -> Qlover.run([], opts) end
    after
      Mix.env(:test)
    end
  end

  test "rejects combining eligible and write-baseline", %{tmp_dir: dir} do
    opts = task_opts(dir)

    assert_raise Mix.Error, ~r/usage/, fn ->
      Qlover.run(["--eligible", "--write-baseline"], opts)
    end
  end

  test "eligible fails without a baseline", %{tmp_dir: dir} do
    opts = task_opts(dir)

    assert_raise Mix.Error, ~r/missing/, fn -> Qlover.run(["--eligible"], opts) end
  end

  test "eligible fails on unreadable baselines", %{tmp_dir: dir} do
    opts = task_opts(dir)
    File.write!(opts[:baseline], "garbage")

    assert_raise Mix.Error, ~r/invalid/, fn -> Qlover.run(["--eligible"], opts) end

    File.write!(opts[:baseline], :erlang.term_to_binary(%{vsn: 0}))
    assert_raise Mix.Error, ~r/invalid/, fn -> Qlover.run(["--eligible"], opts) end
  end

  test "eligible fails when gate inputs change", %{tmp_dir: dir} do
    opts = task_opts(dir)
    gate_file = Path.join([dir, "gate", "input.txt"])
    File.write!(gate_file, "v1")

    assert :ok = Qlover.run(["--write-baseline"], opts)

    File.write!(gate_file, "v2")

    assert_raise Mix.Error, ~r/not eligible/, fn -> Qlover.run(["--eligible"], opts) end
  end

  test "eligible? reports baseline health without raising", %{tmp_dir: dir} do
    compile_beam!(dir, "Health", "  def a, do: :ok\n")
    opts = task_opts(dir)
    settings = Qlover.settings(opts, [])

    refute Qlover.eligible?(settings)

    assert :ok = Qlover.run(["--write-baseline"], opts)
    assert Qlover.eligible?(settings)

    File.write!(opts[:baseline], "garbage")
    refute Qlover.eligible?(settings)

    assert :ok = Qlover.run(["--write-baseline"], opts)
    gate_dir = Path.join(dir, "gate")
    File.write!(Path.join(gate_dir, "input.txt"), "v2")
    refute Qlover.eligible?(settings)
  end

  test "gate passes without fresh export when beams are unchanged", %{tmp_dir: dir} do
    compile_beam!(dir, "Same", "  def a, do: :ok\n")
    opts = task_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts)
    assert :ok = Qlover.run([], opts)

    assert %{beams: beams} = :erlang.binary_to_term(File.read!(opts[:baseline]))
    assert map_size(beams) == 1
    refute File.exists?(opts[:export_path])
  end

  test "gates changed beams with full fresh coverage", %{tmp_dir: dir} do
    compile_beam!(dir, "Pass", "  def a, do: :ok\n")
    opts = task_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts)

    {module, beam} = compile_beam!(dir, "PassV2", "  def a, do: :ok\n  def b, do: :ok\n")
    fresh_export!(beam, opts[:export_path], module, [:a, :b])

    assert :ok = Qlover.run([], opts)
    assert File.regular?(Path.join(opts[:output], "#{module}.html"))
    refute File.exists?(opts[:export_path])
  end

  test "rejects changed beams with partial fresh coverage", %{tmp_dir: dir} do
    compile_beam!(dir, "Partial", "  def a, do: :ok\n")
    opts = task_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts)

    {module, beam} = compile_beam!(dir, "PartialV2", "  def a, do: :ok\n  def b, do: :ok\n")
    fresh_export!(beam, opts[:export_path], module, [:a])

    assert_raise Mix.Error, ~r/incomplete/, fn -> Qlover.run([], opts) end
    refute File.exists?(Path.join(opts[:output], "#{module}.html"))
  end

  test "raises when the fresh export is missing", %{tmp_dir: dir} do
    compile_beam!(dir, "NoExport", "  def a, do: :ok\n")
    opts = task_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts)

    compile_beam!(dir, "NoExportV2", "  def a, do: :ok\n  def b, do: :ok\n")

    assert_raise Mix.Error, ~r/cannot import/, fn -> Qlover.run([], opts) end
  end

  test "gate fails when gate inputs change during the stale run", %{tmp_dir: dir} do
    compile_beam!(dir, "Drift", "  def a, do: :ok\n")
    opts = task_opts(dir)
    gate_file = Path.join([dir, "gate", "input.txt"])
    File.write!(gate_file, "v1")

    assert :ok = Qlover.run(["--write-baseline"], opts)

    File.write!(gate_file, "v2")

    assert_raise Mix.Error, ~r/gate inputs changed during/, fn ->
      Qlover.run([], opts)
    end
  end

  test "gate prunes deleted beams from the baseline", %{tmp_dir: dir} do
    {gone_module, _} = compile_beam!(dir, "Gone", "  def a, do: :ok\n")
    compile_beam!(dir, "Stays", "  def a, do: :ok\n")
    opts = task_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts)
    assert %{beams: beams} = :erlang.binary_to_term(File.read!(opts[:baseline]))
    assert map_size(beams) == 2

    File.rm!(Path.join(dir, "ebin/#{gone_module}.beam"))

    assert :ok = Qlover.run([], opts)
    assert %{beams: pruned} = :erlang.binary_to_term(File.read!(opts[:baseline]))
    assert map_size(pruned) == 1
    refute Enum.any?(Map.keys(pruned), &String.contains?(&1, "Gone"))
  end

  test "reports modules that are not cover compiled" do
    assert_raise Mix.Error, ~r/cannot analyse/, fn ->
      Qlover.module_line_totals(QloverFixNeverCompiled)
    end
  end

  test "rejects beams without abstract code", %{tmp_dir: dir} do
    compile_beam!(dir, "NoDebug", "  def a, do: :ok\n", false)
    opts = task_opts(dir)

    assert_raise Mix.Error, ~r/cover compilation failed/, fn ->
      Qlover.ensure_cover!(opts[:compile_path])
    end
  end

  test "reports a missing beam directory" do
    assert_raise Mix.Error, ~r/cannot list/, fn -> Qlover.beam_hashes("no-such-dir") end
  end

  test "detects new, changed, and identical beams" do
    baseline = %{"a.beam" => "1", "b.beam" => "2", "old.beam" => "3"}
    current = %{"a.beam" => "1", "b.beam" => "changed", "new.beam" => "4"}

    assert Qlover.changed_beams(baseline, current) == ["b.beam", "new.beam"]
    assert Qlover.deleted_beams(baseline, current) == ["old"]
    assert Qlover.deleted_beams(%{}, current) == []
    assert Qlover.deleted_beams(baseline, baseline) == []
  end

  test "maps beam files to modules and enforces totals" do
    assert Qlover.beam_module("some/dir/Elixir.Foo.Bar.beam") == Foo.Bar
    assert :ok = Qlover.enforce_full_coverage!([{Foo, {2, 2}}, {Bar, {0, 0}}])

    assert_raise Mix.Error, ~r/Foo/, fn ->
      Qlover.enforce_full_coverage!([{Foo, {1, 2}}])
    end
  end

  test "resolves default settings" do
    with_env("QLOVER_CACHE_DIR", "/tmp/qlover-test-cache", fn ->
      settings = Qlover.settings([], [])

      assert settings.baseline == "cover/.qlover_baseline"
      assert settings.compile_path == Mix.Project.compile_path()
      assert settings.expansion_export_path == "cover/.qlover_expansion.coverdata"
      assert settings.test_paths == ["test"]
      assert settings.elixirc_paths == ["lib"]
      assert settings.project_root == File.cwd!()
      assert settings.refs_dir == Elixir.Qlover.Tracer.default_dir()
      assert Elixir.Qlover.Tracer.default_dir() == Path.join(File.cwd!(), "cover/.qlover_refs")
      assert settings.cache_dir == "/tmp/qlover-test-cache"
    end)
  end

  test "resolves the default cache dir from the environment" do
    with_env("QLOVER_CACHE_DIR", nil, fn ->
      with_env("XDG_CACHE_HOME", nil, fn ->
        if home = System.user_home() do
          assert Qlover.settings([], []).cache_dir == Path.join([home, ".cache", "qlover"])
        end
      end)

      with_env("XDG_CACHE_HOME", "/tmp/xdg-cache", fn ->
        assert Qlover.settings([], []).cache_dir == "/tmp/xdg-cache/qlover"
      end)

      with_env("QLOVER_CACHE_DIR", "", fn ->
        assert Qlover.settings([], []).cache_dir == nil
      end)

      assert Qlover.default_cache_dir() == Qlover.settings([], []).cache_dir
    end)
  end

  test "test-only edits gate incrementally with fresh proof", %{tmp_dir: dir} do
    {_mod, beam} = compile_beam!(dir, "AttrM", "  def a, do: :ok\n  def b, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "attr_test.exs", "# v1\n")
    old_sha = file_sha!(dir, rel)

    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{"t/attr_test.exs" => entry(old_sha, ["Elixir.QloverFixAttrM"])},
      librefs: %{}
    })

    write_test!(dir, "attr_test.exs", "# v2, still covers M\n")
    fresh_export!(beam, opts[:export_path], QloverFixAttrM, [:a, :b])

    assert :ok = Qlover.run([], opts)
    assert File.regular?(Path.join(opts[:output], "Elixir.QloverFixAttrM.html"))
    refute File.exists?(opts[:export_path])

    snapshot = read_snapshot!(opts)
    assert snapshot.tests[rel].sha == file_sha!(dir, rel)
    assert snapshot.tests[rel].modules == nil
  end

  test "gutted tests fail naming the uncovered module", %{tmp_dir: dir} do
    {mod, beam} = compile_beam!(dir, "GutM", "  def a, do: :ok\n  def b, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "gut_test.exs", "# v1\n")
    old_sha = file_sha!(dir, rel)
    before = write_baseline_v2(opts, %{rel => entry(old_sha, [Atom.to_string(mod)])})

    write_test!(dir, "gut_test.exs", "# v2 covers less\n")
    fresh_export!(beam, opts[:export_path], mod, [:a])

    assert_raise Mix.Error, ~r/QloverFixGutM/, fn -> Qlover.run([], opts) end
    assert File.read!(opts[:baseline]) == before
    refute File.exists?(Path.join(opts[:output], "#{mod}.html"))
  end

  test "new test files pass and extend the snapshot", %{tmp_dir: dir} do
    {mod, beam} = compile_beam!(dir, "NewM", "  def a, do: :ok\n")
    opts = task_opts(dir)
    write_baseline_v2(opts, %{})

    rel = write_test!(dir, "new_test.exs", "# brand new\n")
    fresh_export!(beam, opts[:export_path], mod, [:a])

    assert :ok = Qlover.run([], opts)
    refute File.exists?(opts[:export_path])

    snapshot = read_snapshot!(opts)
    assert snapshot.tests[rel] == %{sha: file_sha!(dir, rel), modules: nil}
  end

  test "new test files without any export fail closed", %{tmp_dir: dir} do
    {_mod, _beam} = compile_beam!(dir, "NewNoExport", "  def a, do: :ok\n")
    opts = task_opts(dir)
    write_baseline_v2(opts, %{})

    write_test!(dir, "new_test.exs", "# brand new\n")

    assert_raise Mix.Error, ~r/cannot import/, fn -> Qlover.run([], opts) end
  end

  test "deleted sole-covering tests fail closed", %{tmp_dir: dir} do
    {mod, _beam} = compile_beam!(dir, "DelM", "  def a, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "del_test.exs", "# doomed\n")
    old_sha = file_sha!(dir, rel)
    write_baseline_v2(opts, %{rel => entry(old_sha, [Atom.to_string(mod)])})
    File.rm!(Path.join(dir, rel))

    assert_raise Mix.Error, ~r/cannot import/, fn -> Qlover.run([], opts) end
  end

  test "non-code fixture changes fall back to full", %{tmp_dir: dir} do
    {_mod, _beam} = compile_beam!(dir, "FixtM", "  def a, do: :ok\n")
    opts = task_opts(dir)
    write_baseline_v2(opts, %{})

    File.write!(Path.join([dir, "t", "data.json"]), ~s({"v": 1}))

    assert_raise Mix.Error, ~r/test fixtures/, fn -> Qlover.run([], opts) end
  end

  test "unattributed test changes fall back to full", %{tmp_dir: dir} do
    compile_beam!(dir, "Unattr", "  def a, do: :ok\n")
    opts = task_opts(dir)
    write_test!(dir, "unattr_test.exs", "# v1\n")

    assert :ok = Qlover.run(["--write-baseline"], opts)
    snapshot = read_snapshot!(opts)
    assert snapshot.tests["t/unattr_test.exs"].modules == nil

    write_test!(dir, "unattr_test.exs", "# v2\n")

    assert_raise Mix.Error, ~r/cannot attribute/, fn -> Qlover.run([], opts) end
  end

  test "changed beams union stale and expansion exports", %{tmp_dir: dir} do
    {mod1, beam1} = compile_beam!(dir, "UniM1", "  def a, do: :ok\n")
    {_mod2, _beam2} = compile_beam!(dir, "UniM2", "  def b, do: :ok\n")
    opts = task_opts(dir)
    old_beams = Qlover.beam_hashes(opts[:compile_path])

    compile_beam!(dir, "UniM1", "  def a, do: :okay\n")
    {mod2, beam2} = compile_beam!(dir, "UniM2", "  def b, do: :still_ok\n")
    write_baseline_v2_raw(opts, old_beams)

    fresh_export!(beam1, opts[:export_path], mod1, [:a])
    fresh_export!(beam2, opts[:expansion_export_path], mod2, [:b])

    assert :ok = Qlover.run([], opts)
    refute File.exists?(opts[:export_path])
    refute File.exists?(opts[:expansion_export_path])
    assert File.regular?(Path.join(opts[:output], "#{mod1}.html"))
    assert File.regular?(Path.join(opts[:output], "#{mod2}.html"))
  end

  test "expansion-only exports satisfy the gate", %{tmp_dir: dir} do
    {mod1, _beam1} = compile_beam!(dir, "TolM1", "  def a, do: :ok\n")
    {_mod2, _beam2} = compile_beam!(dir, "TolM2", "  def b, do: :ok\n")
    opts = task_opts(dir)
    old_beams = Qlover.beam_hashes(opts[:compile_path])

    {mod2, beam2} = compile_beam!(dir, "TolM2", "  def b, do: :still_ok\n")
    write_baseline_v2_raw(opts, old_beams)

    fresh_export!(beam2, opts[:expansion_export_path], mod2, [:b])

    assert :ok = Qlover.run([], opts)
    refute File.exists?(opts[:expansion_export_path])
    _ = mod1
  end

  test "corrupt exports fail closed", %{tmp_dir: dir} do
    {_mod, _beam} = compile_beam!(dir, "Corrupt", "  def a, do: :ok\n")
    opts = task_opts(dir)
    old_beams = Qlover.beam_hashes(opts[:compile_path])

    compile_beam!(dir, "Corrupt", "  def a, do: :okay\n")
    write_baseline_v2_raw(opts, old_beams)
    File.write!(opts[:export_path], "garbage-bytes")
    before = File.read!(opts[:baseline])

    # A corrupt export takes down the cover server instead of returning
    # an error, so the task exits rather than raising. Either way nothing
    # is trusted and the baseline is untouched.
    with_cover_quarantine(dir, fn ->
      result =
        try do
          Qlover.run([], opts)
          :returned
        catch
          :exit, reason -> {:exited, reason}
        end

      assert match?({:exited, _}, result)
    end)

    assert File.read!(opts[:baseline]) == before
  end

  test "unreadable exports fail closed", %{tmp_dir: dir} do
    {_mod, _beam} = compile_beam!(dir, "Unreadable", "  def a, do: :ok\n")
    opts = task_opts(dir)
    old_beams = Qlover.beam_hashes(opts[:compile_path])

    compile_beam!(dir, "Unreadable", "  def a, do: :okay\n")
    write_baseline_v2_raw(opts, old_beams)
    File.write!(opts[:export_path], "garbage-bytes")
    File.chmod!(opts[:export_path], 0o000)

    try do
      assert_raise Mix.Error, ~r/cannot import/, fn -> Qlover.run([], opts) end
    after
      File.chmod!(opts[:export_path], 0o644)
    end
  end

  test "dropped transitive coverage fails naming the helper module", %{tmp_dir: dir} do
    {mod_h, _beam_h} =
      compile_beam!(dir, "AttrH", "  def h, do: [QloverFixAttrM2.a(), QloverFixAttrM2.b()]\n")

    {mod_m, beam_m} = compile_beam!(dir, "AttrM2", "  def a, do: :ok\n  def b, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "h_test.exs", "# calls H.h\n")
    old_sha = file_sha!(dir, rel)

    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{rel => entry(old_sha, [Atom.to_string(mod_h)])},
      librefs: %{Atom.to_string(mod_h) => [Atom.to_string(mod_m)]}
    })

    write_test!(dir, "h_test.exs", "# no longer calls anything\n")
    fresh_export!(beam_m, opts[:export_path], mod_m, [])

    assert_raise Mix.Error, ~r/QloverFixAttrM2/, fn -> Qlover.run([], opts) end
    refute File.exists?(Path.join(opts[:output], "#{mod_m}.html"))
  end

  test "transitive coverage still passing gates", %{tmp_dir: dir} do
    {mod_h, beam_h} =
      compile_beam!(dir, "AttrHP", "  def h, do: [QloverFixAttrM3.a(), QloverFixAttrM3.b()]\n")

    {mod_m, beam_m} = compile_beam!(dir, "AttrM3", "  def a, do: :ok\n  def b, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "hp_test.exs", "# calls H.h\n")
    old_sha = file_sha!(dir, rel)

    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{rel => entry(old_sha, [Atom.to_string(mod_h)])},
      librefs: %{Atom.to_string(mod_h) => [Atom.to_string(mod_m)]}
    })

    write_test!(dir, "hp_test.exs", "# still calls H.h\n")
    cover_beam!(beam_m, mod_m)
    Mix.ensure_application!(:tools)
    _cover = :cover.start()
    {:ok, ^mod_h} = :cover.compile_beam(String.to_charlist(beam_h))
    apply(mod_h, :h, [])
    :ok = :cover.export(String.to_charlist(opts[:export_path]))

    assert :ok = Qlover.run([], opts)
  end

  test "stable chunk hashing ignores volatile metadata" do
    chunks = [
      {~c"Code", <<1, 2>>},
      {~c"ExCk", <<3>>},
      {~c"Dbgi", <<4>>},
      {~c"Docs", <<5>>},
      {~c"CInf", <<6>>},
      {~c"Line", <<7>>}
    ]

    assert Qlover.stable_chunks(chunks) == [{~c"Code", <<1, 2>>}]
    assert Qlover.stable_chunks([]) == []

    reordered = [{~c"CInf", <<9>>}, {~c"Code", <<1, 2>>}, {~c"Dbgi", <<8>>}]
    assert Qlover.stable_chunks(reordered) == Qlover.stable_chunks(chunks)
  end

  test "identical sources hash equally across directories", %{tmp_dir: dir} do
    # Dbgi/Docs/CInf embed absolute source paths, so raw beam bytes always
    # differ across checkouts. Stable hashing must not.
    for sub <- ["worktree-a", "worktree-b"] do
      File.mkdir_p!(Path.join([dir, sub, "ebin"]))
    end

    body = "  def a, do: :ok\n  def b(x), do: x * 2\n"

    for sub <- ["worktree-a", "worktree-b"] do
      subdir = Path.join(dir, sub)

      File.write!(
        Path.join(subdir, "Cross.ex"),
        "defmodule Elixir.QloverFixCross do\n#{body}end\n"
      )

      previous = Code.compiler_options(debug_info: true, docs: true)

      try do
        {:ok, _, _} =
          Kernel.ParallelCompiler.compile_to_path(
            [Path.join(subdir, "Cross.ex")],
            Path.join(subdir, "ebin"),
            return_diagnostics: true
          )
      after
        Code.compiler_options(previous)
      end
    end

    beam_a = Path.join(dir, "worktree-a/ebin/Elixir.QloverFixCross.beam")
    beam_b = Path.join(dir, "worktree-b/ebin/Elixir.QloverFixCross.beam")

    # The property only means something if the raw bytes actually differ.
    assert File.read!(beam_a) != File.read!(beam_b)

    hashes_a = Qlover.beam_hashes(Path.join(dir, "worktree-a/ebin"))
    hashes_b = Qlover.beam_hashes(Path.join(dir, "worktree-b/ebin"))

    assert hashes_a == hashes_b
  end

  test "pure line shifts need no fresh proof", %{tmp_dir: dir} do
    # Identical Code at shifted lines hashes equally: line numbers are
    # labels, and an unchanged suite covers the same expressions.
    for sub <- ["shift-a", "shift-b"] do
      File.mkdir_p!(Path.join([dir, sub, "ebin"]))
    end

    bodies = %{
      "shift-a" => "  def a, do: :ok\n",
      "shift-b" => "\n\n\n  def a, do: :ok\n"
    }

    for {sub, body} <- bodies do
      subdir = Path.join(dir, sub)

      File.write!(
        Path.join(subdir, "Shift.ex"),
        "defmodule Elixir.QloverFixShift do\n#{body}end\n"
      )

      previous = Code.compiler_options(debug_info: true, docs: false)

      try do
        {:ok, _, _} =
          Kernel.ParallelCompiler.compile_to_path(
            [Path.join(subdir, "Shift.ex")],
            Path.join(subdir, "ebin"),
            return_diagnostics: true
          )
      after
        Code.compiler_options(previous)
      end
    end

    assert Qlover.beam_hashes(Path.join(dir, "shift-a/ebin")) ==
             Qlover.beam_hashes(Path.join(dir, "shift-b/ebin"))
  end

  test "unreadable beams fall back to raw content hashes", %{tmp_dir: dir} do
    opts = task_opts(dir)
    File.write!(Path.join(dir, "ebin/Elixir.Garbage.beam"), "not-a-beam")

    hashes = Qlover.beam_hashes(opts[:compile_path])

    assert hashes["Elixir.Garbage.beam"] ==
             :crypto.hash(:sha256, "not-a-beam") |> Base.encode16(case: :lower)
  end

  test "version 1 through 3 baselines are invalid", %{tmp_dir: dir} do
    opts = task_opts(dir)
    File.write!(opts[:baseline], :erlang.term_to_binary(%{vsn: 1, beams: %{}, gate: "x"}))

    assert_raise Mix.Error, ~r/invalid/, fn -> Qlover.run([], opts) end

    for vsn <- [2, 3] do
      File.write!(
        opts[:baseline],
        :erlang.term_to_binary(%{vsn: vsn, beams: %{}, gate: "x", tests: %{}, librefs: %{}})
      )

      assert_raise Mix.Error, ~r/invalid/, fn -> Qlover.run([], opts) end
    end

    assert_raise Mix.Error, ~r/invalid/, fn -> Qlover.run(["--eligible"], opts) end
  end

  test "malformed version 4 baselines are invalid", %{tmp_dir: dir} do
    opts = task_opts(dir)

    for bad <- [
          %{vsn: 4, beams: %{}, gate: "x", tests: [], librefs: %{}},
          %{vsn: 4, beams: %{}, gate: "x", tests: %{}, librefs: []},
          %{vsn: 4, beams: %{}, gate: "x", tests: %{"t/a.exs" => %{modules: []}}, librefs: %{}},
          %{
            vsn: 4,
            beams: %{},
            gate: "x",
            tests: %{"t/a.exs" => %{sha: "1", modules: ["Elixir.X", 42]}},
            librefs: %{}
          },
          %{vsn: 4, beams: [], gate: "x", tests: %{}, librefs: %{}},
          %{vsn: 4, beams: %{}, gate: :atom, tests: %{}, librefs: %{}}
        ] do
      File.write!(opts[:baseline], :erlang.term_to_binary(bad))
      assert_raise Mix.Error, ~r/invalid/, fn -> Qlover.run([], opts) end
    end
  end

  test "write_baseline snapshots partial reference data", %{tmp_dir: dir} do
    compile_beam!(dir, "SnapM", "  def a, do: :ok\n")
    opts = task_opts(dir)
    rel_a = write_test!(dir, "a_test.exs", "# a\n")
    write_test!(dir, "b_test.exs", "# b\n")
    write_record!(opts[:refs_dir], rel_a, file_sha!(dir, rel_a), ["Elixir.QloverFixSnapM"], [])

    assert :ok = Qlover.run(["--write-baseline"], opts)

    snapshot = read_snapshot!(opts)
    assert snapshot.tests[rel_a].modules == ["Elixir.QloverFixSnapM"]
    assert snapshot.tests["t/b_test.exs"].modules == nil
  end

  test "write_baseline without records snapshots unknowns silently", %{tmp_dir: dir} do
    compile_beam!(dir, "SilentM", "  def a, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "c_test.exs", "# c\n")

    assert :ok = Qlover.run(["--write-baseline"], opts)

    snapshot = read_snapshot!(opts)
    assert snapshot.tests == %{rel => %{sha: file_sha!(dir, rel), modules: nil}}
  end

  test "write_baseline prunes dead records", %{tmp_dir: dir} do
    {mod, _beam} = compile_beam!(dir, "PruneM", "  def a, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "keep_test.exs", "# keep\n")
    sha = file_sha!(dir, rel)
    refs = opts[:refs_dir]
    write_record!(refs, rel, sha, ["Elixir.QloverFixPruneM"], [])
    write_record!(refs, "t/gone_test.exs", "olds", ["Elixir.Gone"], [])
    write_record!(refs, "lib/h.ex", "olds", [], ["Elixir.QloverFixPruneM"])
    write_record!(refs, "lib/dead.ex", "olds", [], ["Elixir.Dead"])
    File.write!(Path.join(refs, "garbage.term"), "garbage-bytes")
    File.write!(Path.join(refs, "notes.txt"), "not a record")

    assert :ok = Qlover.run(["--write-baseline"], opts)

    remaining = refs |> File.ls!() |> Enum.sort()

    assert remaining ==
             ["notes.txt", record_filename(rel), record_filename("lib/h.ex")] |> Enum.sort()

    snapshot = read_snapshot!(opts)
    assert snapshot.tests[rel] == %{sha: sha, modules: ["Elixir.QloverFixPruneM"]}
    _ = mod
  end

  test "carries baseline refs without live records", %{tmp_dir: dir} do
    {mod, _beam} = compile_beam!(dir, "CarryM", "  def a, do: :ok\n")
    opts = task_opts(dir)
    rel = write_test!(dir, "carry_test.exs", "# carry\n")
    sha = file_sha!(dir, rel)

    write_baseline_map!(opts, %{
      vsn: 4,
      beams: Qlover.beam_hashes(opts[:compile_path]),
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{rel => entry(sha, ["Elixir.QloverFixCarryM"])},
      librefs: %{}
    })

    assert :ok = Qlover.run([], opts)

    assert File.read!(opts[:baseline]) |> :erlang.binary_to_term() |> Map.get(:tests) ==
             %{rel => %{sha: sha, modules: ["Elixir.QloverFixCarryM"]}}

    _ = mod
  end

  test "test-only drift is not eligible", %{tmp_dir: dir} do
    compile_beam!(dir, "EligT", "  def a, do: :ok\n")
    opts = task_opts(dir)
    write_test!(dir, "elig_test.exs", "# v1\n")

    assert :ok = Qlover.run(["--write-baseline"], opts)
    settings = Qlover.settings(opts, [])
    assert Qlover.eligible?(settings)

    write_test!(dir, "elig_test.exs", "# v2\n")
    refute Qlover.eligible?(settings)
    assert_raise Mix.Error, ~r/not eligible/, fn -> Qlover.run(["--eligible"], opts) end
  end

  test "test_hashes handles absolute roots and missing dirs", %{tmp_dir: dir} do
    opts = task_opts(dir)
    settings = Qlover.settings(opts, [])

    assert Qlover.test_hashes(settings) == %{}

    write_test!(dir, "hash_test.exs", "# hash me\n")

    assert Qlover.test_hashes(settings) == %{
             "t/hash_test.exs" => file_sha!(dir, "t/hash_test.exs")
           }

    abs_settings = %{settings | test_paths: [Path.join(dir, "t")]}

    assert Qlover.test_hashes(abs_settings) == %{
             "t/hash_test.exs" => file_sha!(dir, "t/hash_test.exs")
           }

    missing_settings = %{settings | test_paths: [Path.join(dir, "nope")]}
    assert Qlover.test_hashes(missing_settings) == %{}
  end

  defp write_test!(dir, name, body) do
    rel = "t/#{name}"
    File.write!(Path.join(dir, rel), body)
    rel
  end

  defp file_sha!(dir, rel) do
    :crypto.hash(:sha256, File.read!(Path.join(dir, rel))) |> Base.encode16(case: :lower)
  end

  defp entry(sha, modules), do: %{sha: sha, modules: modules}

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

  defp write_baseline_v2_raw(opts, beams) do
    write_baseline_map!(opts, %{
      vsn: 4,
      beams: beams,
      gate: Qlover.gate_hash(opts[:gate_paths], opts[:project_root]),
      tests: %{},
      librefs: %{}
    })
  end

  defp read_snapshot!(opts) do
    :erlang.binary_to_term(File.read!(opts[:baseline]))
  end

  defp write_record!(refs_dir, rel, sha, modules, defined) do
    File.mkdir_p!(refs_dir)

    record = %{path: rel, sha: sha, modules: modules, defined: defined}
    File.write!(Path.join(refs_dir, record_filename(rel)), :erlang.term_to_binary(record))
  end

  defp record_filename(rel), do: Elixir.Qlover.Attribution.record_filename(rel)

  defp with_env(key, value, fun) do
    old = System.get_env(key)

    if value == nil do
      System.delete_env(key)
    else
      System.put_env(key, value)
    end

    try do
      fun.()
    after
      if old == nil do
        System.delete_env(key)
      else
        System.put_env(key, old)
      end
    end
  end

  # Importing a corrupt export kills the global cover server, which would
  # lose every test's lib hits collected so far. Snapshot cover state
  # around the crash and restore it, so self-coverage stays deterministic
  # regardless of test order.
  defp with_cover_quarantine(dir, fun) do
    Mix.ensure_application!(:tools)
    _ = :cover.start()
    snapshot = Path.join(dir, "quarantine.coverdata")
    :ok = :cover.export(String.to_charlist(snapshot))

    try do
      fun.()
    after
      _ = :cover.start()
      Mix.Project.compile_path() |> cover_beams() |> :cover.compile_beam()
      :ok = :cover.import(String.to_charlist(snapshot))
      File.rm(snapshot)
    end
  end

  defp cover_beams(directory) do
    for beam <- File.ls!(directory),
        String.ends_with?(beam, ".beam"),
        do: String.to_charlist(Path.join(directory, beam))
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

  defp compile_beam!(dir, tag, body, debug_info \\ true) do
    module = String.to_atom("Elixir.QloverFix#{tag}")
    source_path = Path.join(dir, "#{tag}.ex")
    File.write!(source_path, "defmodule #{module} do\n#{body}end\n")
    previous = Code.compiler_options(debug_info: debug_info, docs: false)

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

  defp cover_beam!(beam, module) do
    Mix.ensure_application!(:tools)
    _cover = :cover.start()
    {:ok, ^module} = :cover.compile_beam(String.to_charlist(beam))
    :ok
  end
end
