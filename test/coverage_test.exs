defmodule Qlover.CoverageTest do
  use ExUnit.Case, async: false

  alias Qlover.Coverage

  test "percentages floor to two decimals using integer arithmetic" do
    assert Coverage.percentage(25_000, 25_001) == "99.99"
    assert Coverage.percentage(2, 3) == "66.66"
    assert Coverage.percentage(29, 100) == "29.00"
    assert Coverage.percentage(1, 100_000) == "0.00"
    assert Coverage.percentage(0, 1) == "0.00"
    assert Coverage.percentage(25_001, 25_001) == "100.00"
    assert Coverage.percentage(0, 0) == "100.00"
  end

  test "coverage just below 100% displays as 99.99% and still fails" do
    results = for line <- 1..25_000, do: {{NearComplete, line}, {1, 0}}
    results = [{{NearComplete, 25_001}, {0, 1}} | results]

    output =
      output(fn ->
        assert catch_exit(Coverage.summarize(results, [NearComplete], 100)) == {:shutdown, 3}
      end)

    assert output =~ "99.99% | NearComplete"
    assert output =~ "99.99% | Total"
    assert output =~ "    Coverage:  99.99%"
    assert output =~ "    Threshold: 100.00%"
  end

  test "the gate compares exact coverage rather than the floored display" do
    results = for line <- 1..200, do: {{Example, line}, {if(line <= 133, do: 1, else: 0), 0}}
    assert output(fn -> Coverage.summarize(results, [Example], 66.5) end) =~ "66.50%"

    results = [{{Example, 201}, {1, 0}} | results]
    # 134 / 201 = 66.666...% passes 66.665%, despite displaying 66.66%.
    assert output(fn -> Coverage.summarize(results, [Example], 66.665) end) =~ "66.66%"
  end

  test "merges duplicate lines and omits generated lines and ignored modules" do
    results = [
      {{Example, 0}, {0, 1}},
      {{Example, 1}, {0, 1}},
      {{Example, 1}, {1, 0}},
      {{Example, 2}, {1, 0}},
      {{Ignored, 1}, {0, 1}}
    ]

    output = output(fn -> Coverage.summarize(results, [Example, Empty], 100) end)
    assert output =~ "100.00% | Example"
    assert output =~ "100.00% | Empty"
    assert output =~ "100.00% | Total"
    refute output =~ "Ignored"
    refute output =~ "failed"
    assert output(fn -> Coverage.summarize([], [], 100) end) =~ "100.00% | Total"
  end

  test "only full runs using Mix's enabled summary replace its display" do
    for opts <- [[export: "fresh"], [summary: false], [tool: CustomTool]] do
      with_config(opts, fn ->
        assert Coverage.prepare(["--cover"]) == nil
        assert Mix.Project.config()[:test_coverage] == opts
      end)
    end

    with_config([], fn ->
      assert Coverage.prepare([]) == nil
      assert Coverage.prepare(["--cover", "--export-coverage", "fresh"]) == nil
      assert Coverage.prepare(["--cover", "--export-coverage=fresh"]) == nil
      assert Coverage.finish(nil) == :ok
    end)
  end

  test "full-run summaries restore config and honor ignore modules and thresholds" do
    Mix.ensure_application!(:tools)
    _ = :cover.start()

    for summary <- [true, [threshold: 0]] do
      opts = [summary: summary, ignore_modules: [NeverCovered, ~r/.*/]]

      with_config(opts, fn ->
        assert Coverage.prepare(["--cover"]) == opts
        assert Mix.Project.config()[:test_coverage][:summary] == false
        assert output(fn -> Coverage.finish(opts) end) =~ "100.00% | Total"
        assert Mix.Project.config()[:test_coverage] == opts
      end)
    end
  end

  defmodule Project do
    def project, do: [app: :qlover_coverage_fixture]
  end

  defp with_config(opts, fun) do
    Mix.ProjectStack.post_config(test_coverage: opts)
    Mix.Project.push(Project)

    try do
      fun.()
    after
      Mix.Project.pop()
    end
  end

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
