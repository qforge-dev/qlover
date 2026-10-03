defmodule Mix.Tasks.Test.Qlover do
  @shortdoc "Run tests with incremental coverage gating"

  @moduledoc """
  Runs the test suite with runtime-attributed line coverage in one command:

      mix test.qlover

  Plain `mix test` is unchanged. A successful full run records executable
  lines and their runtime test-file owners. A test-only edit reruns the edited
  file, replaces its old hits, and combines them with other files' unchanged
  hits. Deleting a file gates directly from surviving evidence. Changed code,
  helpers, dependencies, and incompatible or missing evidence use a
  conservative refresh. Passing tests save complete attributed evidence even
  when coverage is incomplete; the coverage gate still fails. Failed tests
  never advance a baseline.

  Shared setup coverage is refreshed with focused runs. File-loading hits
  belong to the loaded test file, including its tracked child processes.
  Deleting files refreshes shared setup without executing remaining tests.

  There is no stale manifest involved: the file list comes from qlover's
  own evidence and reference graph, so selection is deterministic across
  worktrees, and a host `test` alias injecting
  `--stale` cannot shrink it (`--no-stale` is passed first, which wins the
  duplicate-flag resolution).

  Extra arguments are appended to focused selection (`mix test.qlover --seed
  0`). Filtering flags cannot produce reusable coverage, and explicit files
  cannot restrict a full baseline. `--no-stale` forces a full
  suite run and refreshes the baseline. `--dry` compiles pending changes and
  prints the files qlover would select, with their selection reasons, without
  running tests or updating the coverage baseline. The flags `--stale`,
  `--cover`, `--no-cover`, `--export-coverage`, `--failed`, `--partitions`,
  `--dry-run`, `--no-compile` are managed by the task and rejected when passed
  explicitly.

  Path overrides (mirroring `mix qlover`):

    * `--baseline PATH` - baseline file (default: `cover/.qlover_baseline`)
    * `--export PATH` and `--expansion-export PATH` - legacy cover scratch
      export locations; attributed runs use a private, versioned report
      instead of `.coverdata`, which has no file ownership.

  Test failures abort before gating and never update the baseline. Scratch
  exports are deleted after gating (and any leftovers removed before each
  run), so a later `mix test.coverage` never unions a stale partial into a
  full report.

  Each invocation reports `qlover: ran X tests; didn't run Y tests.` Counts
  come from ExUnit (including generated tests and doctests); unchanged files
  reuse counts stored in the baseline and shared cache. ExUnit skips and
  exclusions are included in Y and reported separately. Failed runs also
  print the summary. If a run aborts without reporting counts, unknown
  values are labelled rather than estimated. Older baselines receive one
  full run to collect counts.

  Coverage percentages are rounded down to two decimals so incomplete
  coverage never displays as `100.00%`. Threshold checks use exact counts.

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
  alias Elixir.Qlover.TestCounts

  @managed_flags [
    "--stale",
    "--no-stale",
    "--dry",
    "--cover",
    "--no-cover",
    "--failed",
    "--partitions",
    "--dry-run",
    "--no-compile",
    "--export-coverage"
  ]
  @managed_prefixes ["--export-coverage=", "--partitions="]
  @dry_reasons %{
    baseline: "there is no valid baseline",
    no_stale: "--no-stale forces a full run",
    test_counts: "the baseline has no test counts",
    gate_inputs: "gate inputs changed",
    dependencies: "compiled dependencies changed",
    source_map: "application source locations changed",
    unattributed_baseline: "the baseline has no runtime-attributed evidence",
    test_fixtures: "test fixtures or helpers changed",
    unattributed: "changed tests have no reference data"
  }

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

    Mix.Task.run("compile")
    Elixir.Qlover.Inputs.start()

    try do
      Elixir.Qlover.Native.prepare(settings)

      selection =
        Elixir.Qlover.Native.measure(:selection, fn ->
          selection_plan(
            settings,
            flags,
            runner == (&default_runner/1) and Elixir.Qlover.Coverage.attributed_supported?()
          )
        end)

      if Keyword.get(flags, :dry, false) do
        print_dry_plan(selection, settings, test_args)
      else
        _ = File.rm(settings.export_path)
        _ = File.rm(settings.expansion_export_path)
        execute_plan(selection, settings, runner, test_args)
      end
    after
      Elixir.Qlover.Inputs.stop()
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
  def default_runner([task | args]) when task in ["test", "suite"] do
    if System.get_env("QLOVER_IN_PROCESS") == "1" do
      Elixir.Qlover.Native.run_tests(task, args)
    else
      child_runner(task, args)
    end
  end

  def default_runner(argv), do: run_child(argv, nil)

  defp child_runner(task, args) do
    dir = Mix.Project.manifest_path()
    File.mkdir_p!(dir)

    path =
      Path.join(dir, "qlover-counts-#{System.pid()}-#{System.unique_integer([:positive])}.term")

    coverage_path = path <> ".coverage"

    File.rm(path)

    try do
      code =
        run_child(
          [
            "run",
            "--no-start",
            "--no-compile",
            "-e",
            "Qlover.TestCounts.install(#{inspect(path)}); " <>
              if(task == "suite", do: "Qlover.Coverage.prepare_suite(); ", else: "") <>
              "coverage = Qlover.Coverage.prepare(System.argv()); " <>
              "Mix.Task.run(\"test\", System.argv()); Qlover.Coverage.finish(coverage)",
            "--" | args
          ],
          coverage_path
        )

      report = TestCounts.read_report(path)
      coverage = Elixir.Qlover.Coverage.read_report(coverage_path)
      {code, if(report, do: Map.put(report, :coverage, coverage), else: nil)}
    after
      File.rm(path)
      File.rm(coverage_path)
    end
  end

  defp run_child(argv, coverage_path) do
    {_output, code} =
      System.cmd("mix", argv,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true,
        env: [{"MIX_ENV", to_string(Mix.env())}, {"QLOVER_ATTR_REPORT", coverage_path}]
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

  defp extract_flags(["--no-stale" | rest], flags, test_args) do
    extract_flags(rest, Keyword.put(flags, :no_stale, true), test_args)
  end

  defp extract_flags(["--dry" | rest], flags, test_args) do
    extract_flags(rest, Keyword.put(flags, :dry, true), test_args)
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

  defp selection_plan(settings, flags, attributed_runner?) do
    persist? = not Keyword.get(flags, :dry, false)

    case Qlover.load_baseline(settings, persist: persist?) do
      :error ->
        {:full, :baseline, %{}}

      {:ok, baseline} ->
        select_with_baseline(settings, flags, baseline, attributed_runner?)
    end
  end

  defp select_with_baseline(settings, flags, baseline, attributed_runner?) do
    cond do
      Keyword.get(flags, :no_stale, false) ->
        {:full, :no_stale, baseline}

      not Map.has_key?(baseline, :test_counts) ->
        {:full, :test_counts, baseline}

      attributed_runner? and not Map.has_key?(baseline, :attributed) ->
        {:full, :unattributed_baseline, baseline}

      baseline.gate != Qlover.gate_hash(settings.gate_paths, settings.project_root) ->
        {:full, :gate_inputs, baseline}

      true ->
        current = Qlover.beam_hashes(settings.compile_path)

        case Qlover.attribution_plan_with_reasons(settings, baseline, current) do
          {:full, reason} -> {:full, reason, baseline}
          {:incremental, plan} -> {:incremental, plan, baseline}
        end
    end
  end

  defp execute_plan({:full, reason, baseline}, settings, runner, test_args) do
    Mix.shell().info(full_run_message(reason, settings))
    run_full!(settings, runner, test_args, baseline)
  end

  defp execute_plan(
         {:incremental, %{prove: prove, run: run} = plan, baseline},
         settings,
         runner,
         test_args
       ) do
    refresh_suite? =
      plan.test_changed and run == [] and
        Map.get(Map.get(baseline, :attributed) || %{}, :suite, %{}) != %{}

    run_focused!(settings, runner, test_args, prove, run, baseline, refresh_suite?)
  end

  defp run_full!(settings, runner, test_args, baseline) do
    if runner == (&default_runner/1) and Elixir.Qlover.Coverage.attributed_supported?(),
      do: require_complete_selection!(test_args, true)

    result = runner.(["test", "--no-stale", "--cover"] ++ test_args)

    finish_run!(
      settings,
      baseline,
      result,
      &Qlover.write_baseline!/1,
      runner == (&default_runner/1) and Elixir.Qlover.Coverage.attributed_supported?()
    )
  end

  defp run_focused!(settings, runner, test_args, prove, run, baseline, refresh_suite?) do
    if (run != [] or refresh_suite?) and runner == (&default_runner/1) and
         Elixir.Qlover.Coverage.attributed_supported?(),
       do: require_complete_selection!(test_args, false)

    cond do
      run != [] ->
        Mix.shell().info("qlover: running #{length(run)} focused test file(s) with coverage...")

      refresh_suite? ->
        Mix.shell().info("qlover: refreshing shared setup coverage without running test files...")

      prove == [] ->
        Mix.shell().info("qlover: nothing to re-run; gating on the baseline...")

      Map.has_key?(baseline, :attributed) ->
        Mix.shell().info(
          "qlover: no tests reference #{length(prove)} changed module(s); gating executable lines without running tests..."
        )

      true ->
        Mix.shell().info(
          "qlover: #{length(prove)} module(s) need fresh proof but no tests reference them..."
        )
    end

    result =
      if run != [] or refresh_suite? do
        # NOTE: --no-stale is load-bearing here, not just cosmetic.
        # Host projects often alias `test` with `--stale` injected
        # (e.g. `test: [..., "test --stale"]`); without our own --no-stale
        # first, the alias would intersect our explicit file list with the
        # (possibly fresh) stale manifest and silently run nothing.
        # Appending `--no-stale` wins the duplicate-flag resolution and makes
        # the explicit selection unconditional. User file arguments are
        # appended after the selection: they can only widen the run, which
        # stays sound because all coverage comes from one code version.
        runner.(
          [
            if(refresh_suite?, do: "suite", else: "test"),
            "--no-stale",
            "--cover",
            "--export-coverage",
            export_name(settings.export_path)
          ] ++ run ++ test_args
        )
      else
        {0, %{ran: 0, skipped: 0, files: %{}}}
      end

    try do
      finish_run!(
        settings,
        baseline,
        result,
        &Qlover.gate!/1,
        (run != [] or refresh_suite?) and runner == (&default_runner/1) and
          Elixir.Qlover.Coverage.attributed_supported?()
      )
    after
      _ = File.rm(settings.export_path)
      _ = File.rm(settings.expansion_export_path)
    end
  end

  defp require_complete_selection!(args, full?) do
    if Enum.any?(args, fn arg ->
         (full? and String.ends_with?(arg, ".exs")) or
           Enum.any?(
             ["--only", "--exclude", "--include", "--max-failures"],
             &String.starts_with?(arg, &1)
           )
       end) do
      Mix.raise("filtered test runs cannot establish reusable attributed coverage")
    end
  end

  defp attribution_fallback_message(:test_fixtures) do
    "qlover: test fixtures or helpers changed, running full suite..."
  end

  defp attribution_fallback_message(:unattributed) do
    "qlover: test changes need full attribution, running full suite..."
  end

  defp full_run_message(:baseline, settings), do: first_run_message(settings)

  defp full_run_message(:no_stale, _settings) do
    "qlover: --no-stale requested, running full suite..."
  end

  defp full_run_message(:test_counts, _settings) do
    "qlover: recording test counts, running full suite..."
  end

  defp full_run_message(:unattributed_baseline, _settings) do
    "qlover: legacy baseline needs runtime attribution, running full suite..."
  end

  defp full_run_message(:source_map, _settings) do
    "qlover: source locations changed, running full suite..."
  end

  defp full_run_message(:dependencies, _settings) do
    "qlover: compiled dependencies changed, running full suite..."
  end

  defp full_run_message(:gate_inputs, settings), do: first_run_message(settings)
  defp full_run_message(reason, _settings), do: attribution_fallback_message(reason)

  defp print_dry_plan({:full, reason, _baseline}, settings, test_args) do
    files = TestCounts.test_files(settings)

    Mix.shell().info("qlover: dry run selects the full suite because #{dry_reason(reason)}.")
    print_dry_files(files)
    print_test_args(test_args)
    :ok
  end

  defp print_dry_plan({:incremental, plan, baseline}, settings, test_args) do
    Mix.shell().info("qlover: dry run would run #{length(plan.run)} focused test file(s):")

    Enum.each(plan.run, fn file ->
      Mix.shell().info("  #{file} (#{format_reason(plan.reasons[file])})")
    end)

    if evidence = Map.get(baseline, :attributed) do
      if plan.run == [] and plan.prove != [] do
        Mix.shell().info(
          "qlover: would inspect #{length(plan.prove)} changed module(s) for uncovered lines."
        )
      end

      hashes = Qlover.test_hashes(settings)

      retained =
        Enum.count(evidence.rows, fn {file, row} ->
          hashes[file] == row.sha and file not in plan.run
        end)

      Mix.shell().info("qlover: retaining #{retained} unchanged file coverage row(s).")
    end

    print_test_args(test_args)
    :ok
  end

  defp print_dry_files(files) do
    Mix.shell().info("qlover: would run #{length(files)} test file(s):")
    Enum.each(files, &Mix.shell().info("  #{&1}"))
  end

  defp print_test_args([]), do: :ok

  defp print_test_args(args) do
    Mix.shell().info("qlover: additional Mix test arguments: #{Enum.join(args, " ")}")
  end

  defp dry_reason(reason), do: Map.fetch!(@dry_reasons, reason)

  defp format_reason(%{changed: true, modules: []}), do: "changed test file"

  defp format_reason(%{changed: changed, modules: modules}) do
    prefix = if changed, do: "changed test file; ", else: ""
    names = Enum.map_join(modules, ", ", &String.replace_prefix(&1, "Elixir.", ""))
    prefix <> "references affected modules: " <> names
  end

  defp finish_run!(settings, baseline, {:deferred, paths}, next, require_coverage?) do
    Elixir.Qlover.Native.finalize(fn status ->
      {code, report} = Elixir.Qlover.Native.reports(paths)

      finish_run!(
        settings,
        baseline,
        {if(status == 0, do: code, else: status), report},
        next,
        require_coverage?
      )
    end)
  end

  defp finish_run!(settings, baseline, result, next, require_coverage?) do
    Elixir.Qlover.Inputs.start()
    {code, report} = if is_tuple(result), do: result, else: {result, nil}
    counts = TestCounts.inventory(settings, baseline, report)

    try do
      case code do
        0 ->
          Elixir.Qlover.Native.verify_inputs!()
          coverage = if report, do: report[:coverage]

          if require_coverage? and coverage == nil do
            Mix.raise("attributed coverage report missing or corrupt; baseline not updated")
          end

          if require_coverage? and report.skipped > 0 do
            Mix.raise("skipped/excluded tests cannot establish reusable attributed coverage")
          end

          next.(%{settings | test_counts: counts, coverage: coverage})

        code ->
          Mix.raise("qlover test run failed (exit #{code}); not gating")
      end
    after
      Mix.shell().info(TestCounts.summary(counts, report))
      Elixir.Qlover.Native.receipt(settings, counts)
      Elixir.Qlover.Inputs.stop()
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
