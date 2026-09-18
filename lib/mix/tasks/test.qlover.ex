defmodule Mix.Tasks.Test.Qlover do
  @shortdoc "Run tests with incremental coverage gating"

  @moduledoc """
  Runs the test suite with incremental line-coverage gating in one command:

      mix test.qlover

  Plain `mix test` is left untouched, so single-file runs and ad-hoc flags
  keep working exactly as before. `mix test.qlover` decides by itself:

    * Baseline exists and gate inputs (`test/`, `priv/repo/`, `config/`,
      `mix.exs`, `mix.lock`) are unchanged: runs the stale subset with
      coverage, then gates (`mix test --stale --cover --export-coverage
      .qlover_fresh` + `mix qlover`).
    * Otherwise — first run, missing/invalid baseline, or changed gate
      inputs — runs the full suite with coverage and snapshots a new
      baseline (`mix test --no-stale --cover` + `mix qlover
      --write-baseline`). An info message says which path was taken.

  Extra arguments are passed through to the underlying `mix test`
  invocations (`mix test.qlover --seed 0`). The flags `--stale`,
  `--no-stale`, `--cover`, `--no-cover`, `--export-coverage`, `--failed`,
  `--partitions`, `--dry-run`, `--no-compile` are managed by the task and
  rejected when passed explicitly.

  Path overrides (mirroring `mix qlover`):

    * `--baseline PATH` - baseline file (default: `cover/.qlover_baseline`)
    * `--export PATH` - scratch export (default:
      `cover/.qlover_fresh.coverdata`); custom paths must live under the
      `test_coverage` output dir with a `.coverdata` suffix.
    * `--expansion-export PATH` - second scratch export for the focused
      expansion run (default: `cover/.qlover_expansion.coverdata`).

  Test failures abort before gating and never update the baseline. Scratch
  exports are deleted after gating (and any leftovers removed before each
  run), so a later `mix test.coverage` never unions a stale partial into a
  full report. When test files change but reference data is available, only
  the affected tests rerun in a focused expansion run instead of the full
  suite (see `Mix.Tasks.Qlover`). The expansion passes `--no-stale` so a
  host `test` alias injecting `--stale` cannot silently empty its explicit
  file list, and skips files under `elixirc_paths` (compiled support files
  must never be re-required: that would reload plain code over instrumented
  code and zero their coverage).

  ## The `--qlover` flag spelling

  Mix does not let dependencies add flags to `mix test`, but the same
  spelling is one alias away in your own `mix.exs`:

      defp aliases do
        [
          test: fn
            args ->
              if "--qlover" in args do
                Mix.Task.run("test.qlover", args -- ["--qlover"])
              else
                Mix.Tasks.Test.run(args)
              end
          end
        ]
      end

  With that, `mix test --qlover` gates while bare `mix test` (including
  `mix test test/foo_test.exs`) stays vanilla.
  """

  use Mix.Task

  alias Mix.Tasks.Qlover

  @managed_flags [
    "--stale",
    "--no-stale",
    "--cover",
    "--no-cover",
    "--failed",
    "--partitions",
    "--dry-run",
    "--no-compile",
    "--export-coverage"
  ]
  @managed_prefixes ["--export-coverage=", "--partitions="]

  @impl Mix.Task
  def run(args), do: run(args, [])

  @doc false
  def run(args, options) do
    unless Mix.env() == :test do
      Mix.raise(
        "mix test.qlover must run in the test environment (got #{Mix.env()}); " <>
          "set MIX_ENV=test or add test.qlover to preferred_envs in mix.exs"
      )
    end

    {flags, test_args} = split_args!(args)
    settings = Qlover.settings(options, flags)
    runner = Keyword.get(options, :test_runner, &default_runner/1)
    _ = File.rm(settings.export_path)
    _ = File.rm(settings.expansion_export_path)

    if Qlover.eligible?(settings) do
      Mix.shell().info("Qlover: gate inputs unchanged, running stale subset...")

      run_tests!(
        runner,
        ["--stale", "--cover", "--export-coverage", export_name(settings.export_path)] ++
          test_args
      )

      try do
        Qlover.gate!(settings)
      after
        _ = File.rm(settings.export_path)
        _ = File.rm(settings.expansion_export_path)
      end
    else
      Mix.Task.run("compile")
      run_full_or_attributed!(settings, runner, test_args)
    end
  end

  @doc false
  def split_args!(args) do
    {flags, test_args} = extract_flags(args, [], [])

    case Enum.find(test_args, &managed?/1) do
      nil -> {flags, test_args}
      flag -> Mix.raise("mix test.qlover manages #{flag} itself; drop it and rerun")
    end
  end

  @doc false
  def default_runner(argv) do
    {_output, code} =
      System.cmd("mix", argv,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true,
        env: [{"MIX_ENV", to_string(Mix.env())}]
      )

    code
  end

  defp extract_flags([], flags, test_args), do: {flags, Enum.reverse(test_args)}

  defp extract_flags(["--baseline", path | rest], flags, test_args) do
    extract_flags(rest, Keyword.put(flags, :baseline, path), test_args)
  end

  defp extract_flags(["--export", path | rest], flags, test_args) do
    extract_flags(rest, Keyword.put(flags, :export, path), test_args)
  end

  defp extract_flags(["--baseline=" <> path | rest], flags, test_args) do
    extract_flags(rest, Keyword.put(flags, :baseline, path), test_args)
  end

  defp extract_flags(["--export=" <> path | rest], flags, test_args) do
    extract_flags(rest, Keyword.put(flags, :export, path), test_args)
  end

  defp extract_flags(["--expansion-export", path | rest], flags, test_args) do
    extract_flags(rest, Keyword.put(flags, :expansion_export, path), test_args)
  end

  defp extract_flags(["--expansion-export=" <> path | rest], flags, test_args) do
    extract_flags(rest, Keyword.put(flags, :expansion_export, path), test_args)
  end

  defp extract_flags([arg | rest], flags, test_args) do
    extract_flags(rest, flags, [arg | test_args])
  end

  defp managed?(arg) do
    arg in @managed_flags or Enum.any?(@managed_prefixes, &String.starts_with?(arg, &1))
  end

  defp export_name(path) do
    Path.basename(path, ".coverdata")
  end

  defp run_full_or_attributed!(settings, runner, test_args) do
    case read_baseline_for_plan(settings) do
      {:ok, baseline} ->
        run_attributed_or_full!(settings, runner, test_args, baseline)

      :error ->
        Mix.shell().info(first_run_message(settings))
        run_tests!(runner, ["--no-stale", "--cover"] ++ test_args)
        Qlover.write_baseline!(settings)
    end
  end

  defp run_attributed_or_full!(settings, runner, test_args, baseline) do
    if baseline.gate != Qlover.gate_hash(settings.gate_paths) do
      Mix.shell().info(first_run_message(settings))
      run_tests!(runner, ["--no-stale", "--cover"] ++ test_args)
      Qlover.write_baseline!(settings)
    else
      current = Qlover.beam_hashes(settings.compile_path)

      case Qlover.attribution_plan(settings, baseline, current) do
        {:full, reason} ->
          Mix.shell().info(attribution_fallback_message(reason))
          run_tests!(runner, ["--no-stale", "--cover"] ++ test_args)
          Qlover.write_baseline!(settings)

        {:incremental, %{run: run}} ->
          Mix.shell().info(
            "Qlover: test changes detected, running stale subset with focused expansion..."
          )

          run_tests!(
            runner,
            ["--stale", "--cover", "--export-coverage", export_name(settings.export_path)] ++
              test_args
          )

          if run != [] do
            # NOTE: --no-stale is load-bearing here, not just cosmetic.
            # Host projects often alias `test` with `--stale` injected
            # (e.g. `test: [..., "test --stale"]`), which would intersect
            # our explicit file list with the (possibly fresh) stale
            # manifest and silently run nothing. Appending `--no-stale`
            # wins the duplicate-flag resolution and makes the explicit
            # selection unconditional.
            run_tests!(
              runner,
              [
                "--no-stale",
                "--cover",
                "--export-coverage",
                export_name(settings.expansion_export_path)
              ] ++
                run ++ test_args
            )
          end

          try do
            Qlover.gate!(settings)
          after
            _ = File.rm(settings.export_path)
            _ = File.rm(settings.expansion_export_path)
          end
      end
    end
  end

  defp read_baseline_for_plan(settings) do
    {:ok, Qlover.read_baseline!(settings.baseline)}
  rescue
    Mix.Error -> :error
  end

  defp attribution_fallback_message(:test_fixtures) do
    "Qlover: test fixtures changed, running full suite..."
  end

  defp attribution_fallback_message(:unattributed) do
    "Qlover: test changes need full attribution, running full suite..."
  end

  defp run_tests!(runner, test_args) do
    case runner.(["test" | test_args]) do
      0 -> :ok
      code -> Mix.raise("qlover test run failed (exit #{code}); not gating")
    end
  end

  defp first_run_message(settings) do
    if File.exists?(settings.baseline) do
      "Qlover: baseline missing/invalid or gate inputs changed, running full suite..."
    else
      "Qlover: no baseline yet (first run), running full suite to establish it..."
    end
  end
end
