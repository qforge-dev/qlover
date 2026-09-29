defmodule Qlover.TraceCoverageTest do
  @moduledoc """
  Acceptance tests for runtime, per-test-file line ownership. These intentionally
  fail until qlover can replace one file's coverage contribution independently.
  Fixtures use real child VMs and establish their baselines through test.qlover.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag :trace_coverage
  @moduletag timeout: 120_000
  @root Path.expand("..", __DIR__)

  setup %{tmp_dir: dir} do
    fixture!(dir)
    :ok
  end

  test "editing one file reuses the other file's lines in the same shared module", %{tmp_dir: dir} do
    baseline!(dir)
    write_test!(dir, :a, branches: [:left], revision: 2)

    result = run_qlover(dir)
    assert_success(result)
    assert_executed(result, [:a])
    assert result.output =~ "qlover: ran 1 tests; didn't run 1 tests."

    unchanged = run_qlover(dir)
    assert_success(unchanged)
    assert_executed(unchanged, [])
    assert unchanged.output =~ "qlover: ran 0 tests; didn't run 2 tests."
  end

  test "dry selection includes only the edited file and preserves the baseline", %{tmp_dir: dir} do
    baseline = baseline!(dir)
    write_test!(dir, :a, branches: [:left], revision: 2)

    result = run_qlover(dir, ["--dry"])
    assert_success(result)
    assert_executed(result, [])
    assert baseline_bytes(dir) == baseline
    assert result.output =~ "test/a_test.exs"
    refute result.output =~ "test/b_test.exs"
    assert result.output =~ "would run 1 focused test file(s)"
  end

  test "removing a sole owner's branch fails coverage after running only that file", %{
    tmp_dir: dir
  } do
    baseline = baseline!(dir)
    write_test!(dir, :a, branches: [])

    result = run_qlover(dir)
    assert_coverage_failure(result)
    assert baseline_bytes(dir) == baseline
    assert_executed(result, [:a])
  end

  test "removing a shared line's hit retains the unchanged file's independent contribution", %{
    tmp_dir: dir
  } do
    baseline!(dir)
    write_test!(dir, :a, branches: [:left], common: false)

    result = run_qlover(dir)
    assert_success(result)
    assert_executed(result, [:a])
  end

  test "deleting a redundant owner needs no rerun of the surviving file", %{tmp_dir: dir} do
    write_test!(dir, :b, branches: [:left, :right])
    baseline!(dir)
    File.rm!(Path.join(dir, "test/a_test.exs"))

    result = run_qlover(dir)
    assert_success(result)
    assert_executed(result, [])
    assert result.output =~ "qlover: ran 0 tests; didn't run 1 tests."

    unchanged = run_qlover(dir)
    assert_success(unchanged)
    assert_executed(unchanged, [])
  end

  test "deleting a sole owner reports lost coverage without rerunning unrelated owners", %{
    tmp_dir: dir
  } do
    baseline = baseline!(dir)
    File.rm!(Path.join(dir, "test/a_test.exs"))

    result = run_qlover(dir)
    assert_coverage_failure(result)
    assert baseline_bytes(dir) == baseline
    assert_executed(result, [])
  end

  test "successive edits replace old contributions instead of accumulating stale hits", %{
    tmp_dir: dir
  } do
    write_test!(dir, :b, branches: [:left, :right])
    baseline!(dir)

    # A still covers :left, so B can stop covering it and advance the baseline.
    write_test!(dir, :b, branches: [:right])
    first = run_qlover(dir)
    assert_success(first)
    assert_executed(first, [:b])
    baseline = baseline_bytes(dir)

    # B's superseded :left hit must not rescue A's removal of the last owner.
    write_test!(dir, :a, branches: [])
    second = run_qlover(dir)
    assert_coverage_failure(second)
    assert baseline_bytes(dir) == baseline
    assert_executed(second, [:a])
  end

  test "overlapping async tasks keep their parent files' line ownership separate", %{tmp_dir: dir} do
    write_test!(dir, :a, branches: [:left], task: true)
    write_test!(dir, :b, branches: [:right], task: true)
    baseline!(dir, barrier: true)

    write_test!(dir, :a, branches: [:left], task: true, revision: 2)
    first = run_qlover(dir)
    assert_success(first)
    assert_executed(first, [:a])
    baseline = baseline_bytes(dir)

    write_test!(dir, :a, branches: [])
    second = run_qlover(dir)
    assert_coverage_failure(second)
    assert baseline_bytes(dir) == baseline
    assert_executed(second, [:a])
  end

  test "changed application code cannot reuse coverage from the old module version", %{
    tmp_dir: dir
  } do
    baseline = baseline!(dir)
    path = Path.join(dir, "lib/shared.ex")
    source = File.read!(path)
    File.write!(path, String.replace_suffix(source, "end\n", "  def uncovered, do: :new\nend\n"))

    result = run_qlover(dir)
    assert_coverage_failure(result)
    assert baseline_bytes(dir) == baseline
    assert_executed(result, [:a, :b])
  end

  defp fixture!(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule TraceFixture.MixProject do
      use Mix.Project
      def project do
        [app: :trace_fixture, version: "0.1.0",
         deps: [{:qlover, path: #{inspect(@root)}, runtime: false}],
         elixirc_options: [tracers: [Qlover.Tracer]],
         test_elixirc_options: [tracers: [Qlover.Tracer]],
         test_coverage: [summary: [threshold: 100]]]
      end
    end
    """)

    File.write!(Path.join(dir, "lib/shared.ex"), """
    defmodule TraceFixture.Shared do
      def common, do: :ok

      def branch(side) do
        case side do
          :left -> :left
          :right -> :right
        end
      end
    end
    """)

    File.write!(Path.join(dir, "test/test_helper.exs"), """
    ExUnit.start(max_cases: 2)

    defmodule TraceFixture.Barrier do
      def wait do
        if System.get_env("QLOVER_TEST_BARRIER") == "1" do
          caller = self()
          waiting = Agent.get_and_update(__MODULE__, fn pids ->
            pids = [caller | pids]
            {pids, pids}
          end)

          if length(waiting) == 2 do
            Enum.each(waiting, &send(&1, :both_tasks_started))
          end

          receive do
            :both_tasks_started -> :ok
          after
            5_000 -> raise "both async test tasks must reach the barrier"
          end
        end
      end
    end

    {:ok, _} = Agent.start_link(fn -> [] end, name: TraceFixture.Barrier)
    """)

    write_test!(dir, :a, branches: [:left])
    write_test!(dir, :b, branches: [:right])
    {output, code} = mix(dir, ["deps.get"])
    assert code == 0, output
  end

  defp write_test!(dir, name, opts) do
    calls =
      Enum.map_join(Keyword.fetch!(opts, :branches), "\n", fn side ->
        "assert TraceFixture.Shared.branch(#{inspect(side)}) == #{inspect(side)}"
      end)

    calls =
      if opts[:task] do
        """
        task = Task.async(fn ->
          TraceFixture.Barrier.wait()
          #{calls}
        end)
        Task.await(task, 10_000)
        """
      else
        calls
      end

    common =
      if Keyword.get(opts, :common, true),
        do: "assert TraceFixture.Shared.common() == :ok",
        else: ""

    File.write!(Path.join(dir, "test/#{name}_test.exs"), """
    defmodule TraceFixture.#{String.upcase(to_string(name))}Test do
      use ExUnit.Case, async: true
      require TraceFixture.Shared, warn: false

      test "#{name} revision #{Keyword.get(opts, :revision, 1)}" do
        File.write!(Path.join(System.fetch_env!("QLOVER_TEST_EXECUTIONS"), "#{name}"), "ran\\n", [:append])
        #{common}
        #{calls}
      end
    end
    """)
  end

  defp baseline!(dir, opts \\ []) do
    result = run_qlover(dir, ["--no-stale"], opts)
    assert_success(result)
    assert_executed(result, [:a, :b])
    assert result.output =~ "qlover: ran 2 tests; didn't run 0 tests."
    baseline_bytes(dir)
  end

  defp baseline_bytes(dir), do: File.read!(Path.join(dir, "cover/.qlover_baseline"))

  defp run_qlover(dir, args \\ [], opts \\ []) do
    executions = Path.join(dir, "executions")
    File.rm_rf!(executions)
    File.mkdir_p!(executions)
    {output, code} = mix(dir, ["test.qlover", "--warnings-as-errors", "--seed", "0" | args], opts)

    executed =
      for file <- File.ls!(executions),
          _line <- File.read!(Path.join(executions, file)) |> String.split("\n", trim: true),
          do: file

    %{output: output, code: code, executed: Enum.sort(executed)}
  end

  defp mix(dir, args, opts \\ []) do
    System.cmd("mix", args,
      cd: dir,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"QLOVER_CACHE_DIR", Path.join(dir, "cache")},
        {"QLOVER_TEST_EXECUTIONS", Path.join(dir, "executions")},
        {"QLOVER_TEST_BARRIER", if(opts[:barrier], do: "1", else: "0")},
        {"ERL_FLAGS", "+S 2"}
      ]
    )
  end

  defp assert_success(result), do: assert(result.code == 0, result.output)

  defp assert_coverage_failure(result) do
    assert result.code != 0, result.output
    assert result.output =~ ~r/coverage (?:is incomplete|test failed)/i, result.output
    assert result.output =~ "TraceFixture.Shared", result.output
  end

  defp assert_executed(result, names) do
    expected = names |> Enum.map(&to_string/1) |> Enum.sort()

    assert result.executed == expected,
           "expected #{inspect(expected)}, ran #{inspect(result.executed)}\n#{result.output}"
  end
end
