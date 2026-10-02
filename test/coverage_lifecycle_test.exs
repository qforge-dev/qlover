defmodule Qlover.CoverageLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @root Path.expand("..", __DIR__)

  test "setup_all, setup, and on_exit belong to their test files", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule CoverageLifecycle.MixProject do
      use Mix.Project
      def project do
        [app: :coverage_lifecycle, version: "0.1.0",
         deps: [{:qlover, path: #{inspect(@root)}, runtime: false}],
         elixirc_options: [tracers: [Qlover.Tracer]],
         test_elixirc_options: [tracers: [Qlover.Tracer]],
         test_coverage: [summary: [threshold: 100]]]
      end
    end
    """)

    File.write!(Path.join(dir, "lib/shared.ex"), """
    defmodule CoverageLifecycle.Shared do
      def common, do: :ok
      def branch(:left), do: :left
      def branch(:right), do: :right
    end
    """)

    File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start(max_cases: 2)\n")

    a = Path.join(dir, "test/a_test.exs")

    File.write!(a, """
    defmodule CoverageLifecycle.ATest do
      use ExUnit.Case, async: true
      require CoverageLifecycle.Shared, warn: false
      setup_all do
        CoverageLifecycle.Shared.branch(:left)
        :ok
      end
      setup do
        CoverageLifecycle.Shared.common()
        :ok
      end
      test "a", do: File.write!(System.fetch_env!("QLOVER_LIFECYCLE_MARK"), "a\\n", [:append])
    end
    """)

    File.write!(Path.join(dir, "test/b_test.exs"), """
    defmodule CoverageLifecycle.BTest do
      use ExUnit.Case, async: true
      require CoverageLifecycle.Shared, warn: false
      test "b" do
        on_exit(fn ->
          CoverageLifecycle.Shared.branch(:right)
          CoverageLifecycle.Shared.common()
        end)
        File.write!(System.fetch_env!("QLOVER_LIFECYCLE_MARK"), "b\\n", [:append])
      end
    end
    """)

    assert {_, 0} = command(dir, ["deps.get"])
    {full, 0} = command(dir, ["test.qlover", "--no-stale"])
    assert full =~ "ran 2 tests; didn't run 0 tests."

    baseline = File.read!(Path.join(dir, "cover/.qlover_baseline"))
    original_a = File.read!(a)

    File.write!(
      a,
      String.replace(original_a, "CoverageLifecycle.Shared.branch(:left)", ":left")
    )

    File.rm(Path.join(dir, "markers"))
    {failed, code} = command(dir, ["test.qlover"])
    assert code != 0, failed
    assert failed =~ "coverage is incomplete"
    assert failed =~ "prior owners: [\"test/a_test.exs\"]"
    assert File.read!(Path.join(dir, "markers")) == "a\n"
    refute File.read!(Path.join(dir, "cover/.qlover_baseline")) == baseline

    # A pure source-location shift can keep the executable BEAM hash stable.
    # It must not reuse a previous line-number inventory.
    File.write!(a, original_a)
    source = Path.join(dir, "lib/shared.ex")
    File.write!(source, "\n" <> File.read!(source))
    File.rm!(Path.join(dir, "markers"))
    {shifted, code} = command(dir, ["test.qlover"])
    assert code == 0, shifted
    assert shifted =~ "running full suite"

    assert File.read!(Path.join(dir, "markers")) |> String.split("\n", trim: true) |> Enum.sort() ==
             ["a", "b"]

    b = Path.join(dir, "test/b_test.exs")
    File.write!(b, File.read!(b) <> "\n# changed\n")
    advanced = File.read!(Path.join(dir, "cover/.qlover_baseline"))
    File.rm!(Path.join(dir, "markers"))
    {filtered, code} = command(dir, ["test.qlover", "--only", "not_a_real_tag"])
    assert code != 0, filtered
    assert filtered =~ "filtered test runs cannot establish reusable attributed coverage"
    refute File.exists?(Path.join(dir, "markers"))
    assert File.read!(Path.join(dir, "cover/.qlover_baseline")) == advanced

    File.write!(b, String.replace(File.read!(b), "\n# changed\n", ""))

    File.write!(
      Path.join(dir, "lib/new.ex"),
      "defmodule CoverageLifecycle.New do\n  def missed, do: :nope\nend\n"
    )

    {dry, 0} = command(dir, ["test.qlover", "--dry"])
    assert dry =~ "would run 0 focused test file(s)"
    assert dry =~ "would inspect 1 changed module(s)"
    assert File.read!(Path.join(dir, "cover/.qlover_baseline")) == advanced

    {uncovered, code} = command(dir, ["test.qlover"])
    assert code != 0, uncovered
    assert uncovered =~ "gating executable lines without running tests"
    assert uncovered =~ "qlover coverage is incomplete"
    assert uncovered =~ "CoverageLifecycle.New"
    assert uncovered =~ "ran 0 tests; didn't run 2 tests."
    refute File.exists?(Path.join(dir, "markers"))
    assert File.read!(Path.join(dir, "cover/.qlover_baseline")) == advanced
  end

  defp command(dir, args) do
    System.cmd("mix", args,
      cd: dir,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"ERL_FLAGS", "+S 2"},
        {"QLOVER_CACHE_DIR", Path.join(dir, "cache")},
        {"QLOVER_LIFECYCLE_MARK", Path.join(dir, "markers")}
      ]
    )
  end
end
