defmodule Qlover.CoverageCacheReuseTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @root Path.expand("..", __DIR__)

  test "test-helper evidence refreshes without rerunning unchanged test files", %{
    tmp_dir: dir
  } do
    project = Path.join(dir, "suite")
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(Path.join(project, "test"))

    File.write!(Path.join(project, "mix.exs"), """
    defmodule CoverageSuite.MixProject do
      use Mix.Project
      def project do
        [app: :coverage_suite, version: "0.1.0",
         deps: [{:qlover, path: #{inspect(@root)}, runtime: false}],
         test_coverage: [summary: [threshold: 100]]]
      end
    end
    """)

    File.write!(Path.join(project, "lib/suite.ex"), """
    defmodule CoverageSuite do
      def value, do: :ok
    end
    """)

    File.write!(Path.join(project, "test/test_helper.exs"), """
    ExUnit.start()
    CoverageSuite.value()
    """)

    test_path = Path.join(project, "test/suite_test.exs")

    File.write!(test_path, """
    defmodule CoverageSuiteTest do
      use ExUnit.Case
      test "works", do: assert(true)
    end
    """)

    File.write!(Path.join(project, "test/other_test.exs"), """
    defmodule CoverageSuite.OtherTest do
      use ExUnit.Case
      test "unrelated", do: assert(true)
    end
    """)

    cache = Path.join(dir, "cache")
    assert {_, 0} = run(project, cache, ["deps.get"])
    {first, 0} = run(project, cache, ["test.qlover", "--no-stale"])
    assert first =~ "ran 2 tests; didn't run 0 tests."

    snapshot = Mix.Tasks.Qlover.read_baseline!(Path.join(project, "cover/.qlover_baseline"))
    assert snapshot.attributed.suite["Elixir.CoverageSuite"] != []

    File.write!(test_path, File.read!(test_path) <> "\n# test edit\n")
    {refresh, 0} = run(project, cache, ["test.qlover"])
    assert refresh =~ "running 1 focused test file(s)"
    assert refresh =~ "ran 1 tests; didn't run 1 tests."

    File.rm!(test_path)
    {deleted, 0} = run(project, cache, ["test.qlover"])
    assert deleted =~ "refreshing shared setup coverage"
    assert deleted =~ "ran 0 tests; didn't run 1 tests."
  end

  test "attributed evidence is portable between identical worktrees", %{tmp_dir: dir} do
    cache = Path.join(dir, "shared-cache")
    first = Path.join(dir, "first")
    second = Path.join(dir, "second")

    for project <- [first, second] do
      File.mkdir_p!(Path.join(project, "lib"))
      File.mkdir_p!(Path.join(project, "test"))

      File.write!(Path.join(project, "mix.exs"), """
      defmodule CoverageWorktree.MixProject do
        use Mix.Project
        def project do
          [app: :coverage_worktree, version: "0.1.0",
           deps: [{:qlover, path: #{inspect(@root)}, runtime: false}],
           test_coverage: [summary: [threshold: 100]]]
        end
      end
      """)

      File.write!(Path.join(project, "lib/worktree.ex"), """
      defmodule CoverageWorktree do
        def value, do: :ok
      end
      """)

      File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")

      File.write!(Path.join(project, "test/worktree_test.exs"), """
      defmodule CoverageWorktreeTest do
        use ExUnit.Case
        test "value" do
          File.write!(System.fetch_env!("QLOVER_CACHE_MARKER"), "ran\n", [:append])
          assert CoverageWorktree.value() == :ok
        end
      end
      """)

      assert {_, 0} = run(project, cache, ["deps.get"])
    end

    {full, 0} = run(first, cache, ["test.qlover", "--no-stale"])
    assert full =~ "ran 1 tests; didn't run 0 tests."
    assert File.read!(Path.join(first, "marker")) == "ran\n"

    assert File.read!(Path.join(first, "cover/Elixir.CoverageWorktree.html")) =~
             "class=\"covered\""

    {reused, 0} = run(second, cache, ["test.qlover"])
    assert reused =~ "ran 0 tests; didn't run 1 tests."
    refute File.exists?(Path.join(second, "marker"))
    assert File.regular?(Path.join(second, "cover/.qlover_baseline"))

    source = Path.join(second, "lib/worktree.ex")
    File.write!(source, "\n" <> File.read!(source))
    {shifted, 0} = run(second, cache, ["test.qlover"])
    assert shifted =~ "source locations changed, running full suite"
    assert File.read!(Path.join(second, "marker")) == "ran\n"

    File.write!(Path.join(second, "test/empty_test.exs"), """
    defmodule CoverageWorktree.EmptyTest do
      use ExUnit.Case
      test "no application calls", do: assert(true)
    end
    """)

    {added, 0} = run(second, cache, ["test.qlover"])
    assert added =~ "ran 1 tests; didn't run 1 tests."
    assert File.read!(Path.join(second, "marker")) == "ran\n"

    snapshot = Mix.Tasks.Qlover.read_baseline!(Path.join(second, "cover/.qlover_baseline"))
    assert snapshot.attributed.rows["test/empty_test.exs"].hits == %{}
  end

  defp run(dir, cache, args) do
    System.cmd("mix", args,
      cd: dir,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"ERL_FLAGS", "+S 2"},
        {"QLOVER_CACHE_DIR", cache},
        {"QLOVER_CACHE_MARKER", Path.join(dir, "marker")}
      ]
    )
  end
end
