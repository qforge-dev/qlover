defmodule Mix.Tasks.Test.Qlover do
  @shortdoc "Run tests with incremental coverage gating"

  @moduledoc """
  Runs the test suite with incremental line-coverage gating in one command:

      mix test.qlover

  Plain `mix test` is left untouched, so single-file runs and ad-hoc flags
  keep working exactly as before. `mix test.qlover` decides by itself:

    * Baseline exists and non-test gate inputs (`priv/repo/`, `config/`,
      `mix.exs`, `mix.lock`) match: runs exactly the affected test files
      with coverage, then gates (`mix test --no-stale <files> --cover
      --export-coverage .qlover_fresh` + `mix qlover`). Test-only edits
      stay incremental through per-test attribution.
    * Otherwise — first run, missing/invalid baseline, or changed
      non-test inputs — runs the full suite with coverage and snapshots a
      new baseline (`mix test --no-stale --cover` + `mix qlover
      --write-baseline`). An info message says which path was taken.

  There is no stale manifest involved: the file list comes from qlover's
  own content-keyed reference graph, so selection is deterministic across
  worktrees and machines, and a hostile host `test` alias injecting
  `--stale` cannot shrink it (`--no-stale` is passed first, which wins the
  duplicate-flag resolution).

  Extra arguments are appended to the selection (`mix test.qlover --seed
  0`); extra *file* arguments widen it, which stays sound because all
  coverage still comes from one code version. The flags `--stale`,
  `--no-stale`, `--cover`, `--no-cover`, `--export-coverage`, `--failed`,
  `--partitions`, `--dry-run`, `--no-compile` are managed by the task and
  rejected when passed explicitly.

  Path overrides (mirroring `mix qlover`):

    * `--baseline PATH` - baseline file (default: `cover/.qlover_baseline`)
    * `--export PATH` - scratch export (default:
      `cover/.qlover_fresh.coverdata`); custom paths must live under the
      `test_coverage` output dir with a `.coverdata` suffix.
    * `--expansion-export PATH` - second scratch export accepted by the
      gate (default: `cover/.qlover_expansion.coverdata`).

  Test failures abort before gating and never update the baseline. Scratch
  exports are deleted after gating (and any leftovers removed before each
  run), so a later `mix test.coverage` never unions a stale partial into a
  full report. When test files change but reference data is available, only
  the affected tests rerun in the focused run instead of the full
  suite (see `Mix.Tasks.Qlover`).

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

    Mix.Task.run("compile")

    case Qlover.load_baseline(settings) do
      :error ->
        Mix.shell().info(first_run_message(settings))
        run_tests!(runner, ["--no-stale", "--cover"] ++ test_args)
        Qlover.write_baseline!(settings)

      {:ok, baseline} ->
        run_incremental_or_full!(settings, runner, test_args, baseline)
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

  defp run_incremental_or_full!(settings, runner, test_args, baseline) do
    if baseline.gate != Qlover.gate_hash(settings.gate_paths, settings.project_root) do
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

        {:incremental, %{prove: prove, run: run}} ->
          run_focused!(settings, runner, test_args, prove, run)
      end
    end
  end

  defp run_focused!(settings, runner, test_args, prove, run) do
    cond do
      run != [] ->
        Mix.shell().info("qlover: running #{length(run)} focused test file(s) with coverage...")

      prove == [] ->
        Mix.shell().info("qlover: nothing to re-run; gating on the baseline...")

      true ->
        Mix.shell().info(
          "qlover: #{length(prove)} module(s) need fresh proof but no tests reference them..."
        )
    end

    if run != [] do
      # NOTE: --no-stale is load-bearing here, not just cosmetic.
      # Host projects often alias `test` with `--stale` injected
      # (e.g. `test: [..., "test --stale"]`); without our own --no-stale
      # first, the alias would intersect our explicit file list with the
      # (possibly fresh) stale manifest and silently run nothing.
      # Appending `--no-stale` wins the duplicate-flag resolution and makes
      # the explicit selection unconditional. User file arguments are
      # appended after the selection: they can only widen the run, which
      # stays sound because all coverage comes from one code version.
      run_tests!(
        runner,
        [
          "--no-stale",
          "--cover",
          "--export-coverage",
          export_name(settings.export_path)
        ] ++ run ++ test_args
      )
    end

    try do
      Qlover.gate!(settings)
    after
      _ = File.rm(settings.export_path)
      _ = File.rm(settings.expansion_export_path)
    end
  end

  defp attribution_fallback_message(:test_fixtures) do
    "qlover: test fixtures changed, running full suite..."
  end

  defp attribution_fallback_message(:unattributed) do
    "qlover: test changes need full attribution, running full suite..."
  end

  defp run_tests!(runner, test_args) do
    case runner.(["test" | test_args]) do
      0 -> :ok
      code -> Mix.raise("qlover test run failed (exit #{code}); not gating")
    end
  end

  defp first_run_message(settings) do
    if File.exists?(settings.baseline) do
      "qlover: baseline missing/invalid or gate inputs changed, running full suite..."
    else
      "qlover: no baseline yet (first run), running full suite to establish it..."
    end
  end
end
