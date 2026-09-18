defmodule Qlover.TestCountsTest do
  use ExUnit.Case, async: false

  alias Qlover.TestCounts
  alias Mix.Tasks.Qlover
  alias Mix.Tasks.Test.Qlover, as: TestQlover

  @moduletag :tmp_dir

  defmodule PatternProject do
    def project, do: [app: :qlover_counts_fixture]
  end

  test "after-suite callback counts registered tests and leaves formatters alone", %{tmp_dir: dir} do
    path = Path.join(dir, "counts")
    previous = Application.fetch_env!(:ex_unit, :after_suite)
    formatters = ExUnit.configuration()[:formatters]

    try do
      TestCounts.install(path)
      [callback | ^previous] = Application.fetch_env!(:ex_unit, :after_suite)
      callback.(%{total: 12, skipped: 2, excluded: 3, failures: 1})
      assert %{ran: 7, skipped: 5, files: files} = TestCounts.read_report(path)
      assert files["test/test_counts_test.exs"] == length(__MODULE__.__ex_unit__().tests)
      assert files["test/test_helper.exs"] == 0
      assert ExUnit.configuration()[:formatters] == formatters
      callback.(%{total: 12, skipped: 2, excluded: 3, failures: 1})
      assert %{ran: 14, skipped: 10, runs: 2} = TestCounts.read_report(path)
    after
      Application.put_env(:ex_unit, :after_suite, previous)
    end
  end

  test "missing or corrupt reports cannot produce fabricated savings", %{tmp_dir: dir} do
    path = Path.join(dir, "counts")
    assert TestCounts.read_report(path) == nil

    for data <- [
          "broken",
          :erlang.term_to_binary(:wrong),
          :erlang.term_to_binary(%{ran: -1, skipped: 0, files: %{}}),
          :erlang.term_to_binary(%{ran: 0, skipped: 0, runs: 1, files: %{"a" => -1}})
        ] do
      File.write!(path, data)
      assert TestCounts.read_report(path) == nil
    end

    assert TestCounts.summary(%{}, nil) ==
             "qlover: ran unknown tests; didn't run unknown tests. Test run did not report counts."
  end

  test "inventory refreshes edited files, removes deleted files and retains unchanged counts", %{
    tmp_dir: dir
  } do
    settings = settings(dir)
    write!(dir, "a_test.exs", "# same")
    write!(dir, "b_test.exs", "# before")
    write!(dir, "deleted_test.exs", "# before")

    counts =
      TestCounts.inventory(
        settings,
        %{},
        report(9, %{"a_test.exs" => 3, "b_test.exs" => 2, "deleted_test.exs" => 4})
      )

    baseline = %{test_counts: counts}

    write!(dir, "b_test.exs", "# after")
    write!(dir, "new_test.exs", "# new")
    File.rm!(Path.join(dir, "deleted_test.exs"))
    fresh = report(6, %{"b_test.exs" => 5, "new_test.exs" => 1})
    updated = TestCounts.inventory(settings, baseline, fresh)
    assert Map.keys(updated) |> Enum.sort() == ["a_test.exs", "b_test.exs", "new_test.exs"]
    assert updated["a_test.exs"].count == 3
    assert updated["b_test.exs"].count == 5
    assert TestCounts.summary(updated, fresh) == "qlover: ran 6 tests; didn't run 3 tests."
    assert TestCounts.summary(updated, report(0)) == "qlover: ran 0 tests; didn't run 9 tests."

    # Without a fresh report, an edited file's previous size is not trusted.
    unknown = TestCounts.inventory(settings, baseline, nil)
    assert unknown["b_test.exs"].count == nil
    assert TestCounts.summary(unknown, report(1)) =~ "didn't run unknown tests. A full run"
  end

  test "tag filters are included in not-run counts and identified separately" do
    counts = %{"a" => %{count: 8}}

    assert TestCounts.summary(counts, %{report(2) | skipped: 3}) ==
             "qlover: ran 2 tests; didn't run 6 tests. 3 skipped/excluded by ExUnit."

    assert TestCounts.summary(counts, Map.put(report(4), :runs, 2)) ==
             "qlover: ran 4 tests; didn't run 12 tests."
  end

  test "only well-formed counts may be reused from a baseline" do
    assert TestCounts.valid_inventory?(%{"a" => %{sha: "hash", count: 3}})
    assert TestCounts.valid_inventory?(%{"a" => %{sha: "hash", count: nil}})
    refute TestCounts.valid_inventory?(nil)
    refute TestCounts.valid_inventory?(%{"a" => %{sha: "hash", count: -1}})
    refute TestCounts.valid_inventory?(%{"a" => :broken})
  end

  test "custom test patterns and load filters retain unknown files until observed", %{
    tmp_dir: dir
  } do
    settings = settings(dir)

    for file <- ["a_spec.exs", "b_spec.exs", "c_spec.exs", "helper.exs"],
        do: write!(dir, file, "# test")

    Mix.ProjectStack.post_config(test_pattern: "*_spec.exs")
    Mix.Project.push(PatternProject)

    try do
      assert map_size(TestCounts.inventory(settings, %{}, nil)) == 3
    after
      Mix.Project.pop()
    end

    Mix.ProjectStack.post_config(
      test_load_filters: [~r/^a_spec/, "b_spec.exs", &(&1 == "c_spec.exs")]
    )

    Mix.Project.push(PatternProject)

    try do
      assert map_size(TestCounts.inventory(settings, %{}, nil)) == 3
    after
      Mix.Project.pop()
    end
  end

  test "full, cached, focused and failed invocations report counts and only persist successful runs",
       %{tmp_dir: dir} do
    settings = settings(dir)
    opts = Map.to_list(settings)
    write!(dir, "a_test.exs", "# a")
    write!(dir, "b_test.exs", "# b")

    full = fn _ -> {0, report(5, %{"a_test.exs" => 2, "b_test.exs" => 3})} end

    assert output(fn -> TestQlover.run([], Keyword.put(opts, :test_runner, full)) end) =~
             "qlover: ran 5 tests; didn't run 0 tests."

    before = File.read!(settings.baseline)

    File.rm!(settings.baseline)

    assert output(fn ->
             TestQlover.run(
               [],
               Keyword.put(opts, :test_runner, fn _ -> flunk("cache should avoid running") end)
             )
           end) =~
             "qlover: ran 0 tests; didn't run 5 tests."

    assert File.read!(settings.baseline) == before

    write!(dir, "new_test.exs", "# added")
    failing = fn _ -> {2, report(1, %{"new_test.exs" => 1})} end

    assert output(fn ->
             assert_raise Mix.Error, ~r/exit 2/, fn ->
               TestQlover.run([], Keyword.put(opts, :test_runner, failing))
             end
           end) =~ "qlover: ran 1 tests; didn't run 5 tests."

    assert File.read!(settings.baseline) == before

    passing = fn _ ->
      File.write!(settings.export_path, "fresh")
      {0, report(1, %{"new_test.exs" => 1})}
    end

    assert output(fn -> TestQlover.run([], Keyword.put(opts, :test_runner, passing)) end) =~
             "qlover: ran 1 tests; didn't run 5 tests."

    assert Qlover.read_baseline!(settings.baseline).test_counts["new_test.exs"].count == 1
  end

  test "older baselines get one full run to learn test counts", %{tmp_dir: dir} do
    settings = settings(dir)
    Qlover.write_baseline!(settings)

    runner = fn args ->
      assert args == ["test", "--no-stale", "--cover"]
      {0, report(0)}
    end

    assert output(fn ->
             TestQlover.run([], Keyword.put(Map.to_list(settings), :test_runner, runner))
           end) =~
             "recording test counts, running full suite"
  end

  test "child runner returns a machine-readable report even for an empty selection" do
    assert {0, %{ran: 0, skipped: 0}} =
             TestQlover.default_runner([
               "test",
               "--no-stale",
               "--no-compile",
               "test/test_helper.exs"
             ])
  end

  test "real ExUnit counts generated tests, doctests, multiple modules and focused failures", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule CountsDemo.MixProject do
      use Mix.Project
      def project do
        [app: :counts_demo, version: "0.1.0",
         deps: [{:qlover, path: #{inspect(File.cwd!())}, runtime: false}],
         elixirc_options: [tracers: [Qlover.Tracer]],
         test_elixirc_options: [tracers: [Qlover.Tracer]],
         test_coverage: [summary: [threshold: 100]],
         aliases: [test: ["test --stale"]]]
      end
    end
    """)

    File.write!(Path.join(dir, "lib/a.ex"), """
    defmodule CountsDemo.A do
      @doc \"\"\"
          iex> CountsDemo.A.value()
          1
      \"\"\"
      def value, do: 1
    end
    """)

    File.write!(
      Path.join(dir, "lib/b.ex"),
      "defmodule CountsDemo.B do\n  def value, do: 2\nend\n"
    )

    File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(dir, "test/a_test.exs"), """
    defmodule CountsDemo.ATest do
      use ExUnit.Case
      doctest CountsDemo.A
      for n <- 1..2 do
        test "generated \#{n}", do: assert(CountsDemo.A.value() == 1)
      end
    end
    defmodule CountsDemo.OtherATest do
      use ExUnit.Case
      test "same file", do: assert(CountsDemo.A.value() == 1)
    end
    """)

    File.write!(Path.join(dir, "test/b_test.exs"), """
    defmodule CountsDemo.BTest do
      use ExUnit.Case
      test "b", do: assert(CountsDemo.B.value() == 2)
    end
    """)

    run = fn args ->
      System.cmd("mix", args,
        cd: dir,
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "test"},
          {"QLOVER_CACHE_DIR", Path.join(dir, "cache")},
          {"ERL_FLAGS", "+S 2"}
        ]
      )
    end

    assert {_, 0} = run.(["deps.get"])
    {full, code} = run.(["test.qlover"])
    assert code == 0, full
    assert full =~ "qlover: ran 5 tests; didn't run 0 tests."
    {unchanged, 0} = run.(["test.qlover"])
    assert unchanged =~ "qlover: ran 0 tests; didn't run 5 tests."

    file = Path.join(dir, "test/b_test.exs")
    File.write!(file, File.read!(file) |> String.replace("== 2", "== 3"))
    {failed, code} = run.(["test.qlover"])
    assert code != 0
    assert failed =~ "qlover: ran 1 tests; didn't run 4 tests."
    File.write!(file, File.read!(file) |> String.replace("== 3", "== 1 + 1"))
    {focused, code} = run.(["test.qlover"])
    assert code == 0, focused
    assert focused =~ "qlover: ran 1 tests; didn't run 4 tests."

    File.write!(
      file,
      File.read!(file) |> String.replace("  test \"b\"", "  @tag :skip\n  test \"b\"")
    )

    {skipped, code} = run.(["test.qlover"])
    assert code != 0
    assert skipped =~ "qlover: ran 0 tests; didn't run 5 tests. 1 skipped/excluded by ExUnit."

    File.rm!(file)
    File.rm!(Path.join(dir, "lib/b.ex"))
    {deleted, code} = run.(["test.qlover"])
    assert code == 0, deleted
    assert deleted =~ "qlover: ran 0 tests; didn't run 4 tests."

    File.rm!(Path.join(dir, "cover/.qlover_baseline"))

    File.write!(Path.join(dir, "lib/uncovered.ex"), """
    defmodule CountsDemo.Uncovered do
      def missed, do: :never_called
    end
    """)

    {incomplete, code} = run.(["test.qlover"])
    assert code != 0
    assert incomplete =~ "Coverage test failed, threshold not met:"
    assert incomplete =~ "    Coverage:  50.00%"
    assert incomplete =~ "    Threshold: 100.00%"
    assert incomplete =~ "qlover: ran 4 tests; didn't run 0 tests."
    refute File.exists?(Path.join(dir, "cover/.qlover_baseline"))
  end

  defp settings(dir) do
    state = Path.join(dir, ".state")
    File.mkdir_p!(Path.join(state, "ebin"))

    Qlover.settings(
      [
        project_root: dir,
        compile_path: Path.join(state, "ebin"),
        test_paths: ["."],
        gate_paths: [],
        refs_dir: Path.join(state, "refs"),
        cache_dir: Path.join(state, "cache"),
        baseline: Path.join(state, "baseline"),
        export_path: Path.join(state, "fresh.coverdata"),
        expansion_export_path: Path.join(state, "expansion.coverdata"),
        output: Path.join(state, "html")
      ],
      []
    )
  end

  defp write!(dir, file, body), do: File.write!(Path.join(dir, file), body)
  defp report(ran, files \\ %{}), do: %{ran: ran, skipped: 0, files: files}

  defp output(fun) do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    try do
      ExUnit.CaptureIO.capture_io(fun)
    after
      Mix.shell(previous)
    end
  end
end
