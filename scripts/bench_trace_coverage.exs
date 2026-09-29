#!/usr/bin/env elixir
# Reproducible, small-fixture smoke benchmark. Run `elixir scripts/bench_trace_coverage.exs`.
# This is not a substitute for benchmarking a representative host project.

root = Path.expand("..", __DIR__)
base = System.get_env("QLOVER_BENCH_ROOT") || System.tmp_dir!()
dir = Path.join(base, "qlover-bench-#{System.pid()}-#{System.unique_integer([:positive])}")
File.mkdir!(dir)

try do
  File.mkdir_p!(Path.join(dir, "lib"))
  File.mkdir_p!(Path.join(dir, "test"))

  File.write!(Path.join(dir, "mix.exs"), """
  defmodule QloverBenchmark.MixProject do
    use Mix.Project
    def project do
      [app: :qlover_benchmark, version: "0.1.0",
       deps: [{:qlover, path: #{inspect(root)}, runtime: false}],
       test_coverage: [summary: [threshold: 100]]]
    end
  end
  """)

  File.write!(Path.join(dir, "lib/shared.ex"), """
  defmodule QloverBenchmark.Shared do
    def common, do: :ok
    def branch(:left), do: :left
    def branch(:right), do: :right
  end
  """)

  File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start(max_cases: 2)\n")

  for {file, branch} <- [{"a", "left"}, {"b", "right"}] do
    File.write!(Path.join(dir, "test/#{file}_test.exs"), """
    defmodule QloverBenchmark.#{String.upcase(file)}Test do
      use ExUnit.Case, async: true
      test "#{file}" do
        assert QloverBenchmark.Shared.common() == :ok
        assert QloverBenchmark.Shared.branch(:#{branch}) == :#{branch}
      end
    end
    """)
  end

  run = fn args ->
    start = System.monotonic_time(:millisecond)

    {output, code} =
      System.cmd("mix", args,
        cd: dir,
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "test"},
          {"ERL_FLAGS", "+S 2"},
          {"QLOVER_CACHE_DIR", Path.join(dir, "cache")}
        ]
      )

    if code != 0, do: raise("#{Enum.join(args, " ")} failed:\n#{output}")
    {System.monotonic_time(:millisecond) - start, output}
  end

  run.(["deps.get"])
  {native_ms, _} = run.(["test", "--no-stale", "--cover", "--warnings-as-errors"])
  {full_ms, _} = run.(["test.qlover", "--no-stale", "--warnings-as-errors"])
  baseline = Path.join(dir, "cover/.qlover_baseline")
  full = :erlang.binary_to_term(File.read!(baseline)).attributed
  full_bytes = File.stat!(baseline).size

  a = Path.join(dir, "test/a_test.exs")
  File.write!(a, File.read!(a) <> "\n# incremental edit\n")
  {focused_ms, focused_output} = run.(["test.qlover", "--warnings-as-errors"])
  focused = :erlang.binary_to_term(File.read!(baseline)).attributed

  IO.puts("native full: #{native_ms} ms; attributed full: #{full_ms} ms; focused edit: #{focused_ms} ms")
  IO.puts("full report metrics: #{inspect(full.last_run.metrics)}")
  IO.puts("focused report metrics: #{inspect(focused.last_run.metrics)}")
  IO.puts("manifest bytes: full #{full_bytes}, after edit #{File.stat!(baseline).size}")
  IO.puts("conservative fallbacks: #{if focused_output =~ "running full suite", do: 1, else: 0}/1 edits")
after
  File.rm_rf!(dir)
end
