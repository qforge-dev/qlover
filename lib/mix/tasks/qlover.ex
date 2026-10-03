defmodule Mix.Tasks.Qlover do
  @shortdoc "Gates incremental coverage from stale test runs"

  @moduledoc """
  Gates a native-cover reference snapshot when invoked directly. The
  `mix test.qlover` runner also uses this task's snapshot and planning APIs to
  gate its runtime-attributed line ownership.

      mix qlover --eligible
      mix test --stale --cover --export-coverage .qlover_fresh
      mix qlover
      mix qlover --write-baseline

  The snapshot records compiled-module and test hashes, non-test gate inputs,
  and compiler references. Attributed snapshots additionally record the full
  executable-line inventory, per-file hits, source-map identity, dependency
  identity, and runtime/backend compatibility. Changed files replace their
  rows, never accumulate historical coverage. Standalone native-cover exports
  cannot be upgraded into attributed evidence without a new full run.

  Prefer `mix test.qlover`, which runs the whole flow (eligible → stale →
  gate, else full → snapshot) in one command.

  ## Options

  The task is normally driven by the `cover.sh` wrapper, but the paths can
  be overridden for testing or custom layouts:

    * `--baseline PATH` - baseline file (default: `cover/.qlover_baseline`)
    * `--export NAME` - fresh export name under the cover output dir
      (default: `cover/.qlover_fresh.coverdata`)
    * `--expansion-export PATH` - second scratch export for the focused
      expansion run (default: `cover/.qlover_expansion.coverdata`)

  A successful gate deletes the scratch exports so a later
  `mix test.coverage` never unions a stale partial into a full report.

  ## Sharing baselines across worktrees

  Every snapshot is also written through to a shared content-addressed
  cache, and a missing or invalid local baseline is fetched from it:

      QLOVER_CACHE_DIR=~/.cache/qlover  # the default (XDG-aware)

  The cache key is derived from the beam hashes, gate hash, and test
  hashes, so a hit means byte-identical content: the gate re-verifies the
  fetched baseline against the local tree exactly as if it were local, so
  a cache hit can never pass where a local baseline would fail. Set
  `QLOVER_CACHE_DIR` to another directory to share across checkouts, to
  `""` to disable the cache, or keep the default for a personal
  cross-worktree cache. Tracer records merge the same way (per-file
  content keys; last-writer-wins races only ever degrade to a full run).

  ## Test attribution

  Changed application modules still use compiler references alongside prior
  runtime owners. Enable `Qlover.Tracer` in the host project:

      # mix.exs
      def project do
        [...,
         elixirc_options: [tracers: [Qlover.Tracer]],
         test_elixirc_options: [tracers: [Qlover.Tracer]]]
      end

  A baseline from the standalone native-cover command has no runtime owners.
  `mix test.qlover` gives it one attributed full refresh before focused edits.
  Direct `mix qlover` invocations with legacy snapshots retain the conservative
  native-cover gate; use `mix test.qlover` to refresh attributed snapshots.
  """

  use Mix.Task

  alias Qlover.Attribution

  @vsn 4
  @baseline_default "cover/.qlover_baseline"
  @export_default "cover/.qlover_fresh.coverdata"
  @expansion_export_default "cover/.qlover_expansion.coverdata"
  @output_default "cover"
  @gate_roots ["priv/repo", "config", "mix.exs", "mix.lock"]
  @test_roots ["test"]

  @impl Mix.Task
  def run(args), do: run(args, [])

  @doc false
  def run(args, options) do
    unless Mix.env() == :test do
      Mix.raise(
        "mix qlover must run in the test environment (got #{Mix.env()}); " <>
          "set MIX_ENV=test or add qlover tasks to preferred_envs in mix.exs"
      )
    end

    {flags, remaining} =
      OptionParser.parse!(args,
        strict: [
          eligible: :boolean,
          write_baseline: :boolean,
          baseline: :string,
          export: :string,
          expansion_export: :string
        ]
      )

    if remaining != [] do
      Mix.raise("usage: mix qlover [--eligible | --write-baseline]")
    end

    if flags[:eligible] && flags[:write_baseline] do
      Mix.raise("usage: mix qlover [--eligible | --write-baseline]")
    end

    settings = settings(options, flags)

    cond do
      flags[:eligible] -> check_eligible!(settings)
      flags[:write_baseline] -> write_baseline!(settings)
      true -> gate!(settings)
    end
  end

  @doc false
  def settings(options, flags) do
    %{
      baseline: flags[:baseline] || Keyword.get(options, :baseline, @baseline_default),
      export_path: flags[:export] || Keyword.get(options, :export_path, @export_default),
      expansion_export_path:
        flags[:expansion_export] ||
          Keyword.get(options, :expansion_export_path, @expansion_export_default),
      compile_path: Keyword.get(options, :compile_path, Mix.Project.compile_path()),
      gate_paths: Keyword.get(options, :gate_paths, @gate_roots),
      test_paths:
        Keyword.get(options, :test_paths, Mix.Project.config()[:test_paths] || @test_roots),
      test_counts: Keyword.get(options, :test_counts),
      elixirc_paths:
        Keyword.get(options, :elixirc_paths, Mix.Project.config()[:elixirc_paths] || ["lib"]),
      project_root: Keyword.get(options, :project_root, File.cwd!()),
      refs_dir: Keyword.get(options, :refs_dir, Qlover.Tracer.default_dir()),
      cache_dir: Keyword.get(options, :cache_dir, default_cache_dir()),
      output: Keyword.get(options, :output, @output_default),
      coverage: Keyword.get(options, :coverage)
    }
  end

  @doc false
  def default_cache_dir do
    case System.get_env("QLOVER_CACHE_DIR") do
      nil -> default_cache_home(System.get_env("XDG_CACHE_HOME"), System.user_home())
      "" -> nil
      dir -> dir
    end
  end

  @doc false
  def default_cache_home(xdg, home) do
    cond do
      is_binary(xdg) -> Path.join(xdg, "qlover")
      is_binary(home) -> Path.join([home, ".cache", "qlover"])
      true -> nil
    end
  end

  @doc false
  def check_eligible!(settings) do
    baseline = read_baseline!(settings.baseline)

    if baseline.gate == gate_hash(settings.gate_paths, settings.project_root) and
         test_identity?(baseline.tests, test_hashes(settings)) do
      Mix.shell().info("qlover is eligible: gate inputs unchanged.")
      :ok
    else
      Mix.raise("qlover is not eligible: gate inputs changed; run full coverage")
    end
  end

  @doc false
  def eligible?(settings) do
    with {:ok, contents} <- File.read(settings.baseline),
         {:ok, baseline} <- decode_baseline(contents),
         true <- baseline.gate == gate_hash(settings.gate_paths, settings.project_root) do
      test_identity?(baseline.tests, test_hashes(settings))
    else
      _error -> false
    end
  end

  @doc false
  def write_baseline!(settings) do
    Mix.Task.run("compile")
    {prior_tests, prior_librefs, prior_beams} = read_prior_baseline(settings)
    current = beam_hashes(settings.compile_path)
    gate = gate_hash(settings.gate_paths, settings.project_root)
    snapshot = build_snapshot(settings, {prior_tests, prior_librefs, prior_beams}, current, gate)

    snapshot =
      if settings.coverage do
        evidence = Elixir.Qlover.Coverage.Evidence.full!(settings, settings.coverage, snapshot)
        Map.put(snapshot, :attributed, evidence)
      else
        snapshot
      end

    persist_baseline!(settings, snapshot)
    warn_unknown_refs(snapshot.tests)
    prune_records!(settings, snapshot, current)
    Mix.shell().info("Wrote qlover baseline to #{settings.baseline}.")
    if settings.coverage, do: Elixir.Qlover.Coverage.Evidence.gate!(snapshot.attributed, %{})
    :ok
  end

  @doc false
  def gate!(settings) do
    Mix.Task.run("compile")
    baseline = load_baseline!(settings)
    gate = gate_hash(settings.gate_paths, settings.project_root)

    if baseline.gate != gate do
      Mix.raise("gate inputs changed during the stale run; run full coverage")
    end

    current = beam_hashes(settings.compile_path)

    if Map.get(baseline, :attributed) do
      gate_attributed!(settings, baseline, current, gate)
    else
      gate_legacy!(settings, baseline, current, gate)
    end
  end

  defp gate_legacy!(settings, baseline, current, gate) do
    case attribution_plan(settings, baseline, current) do
      {:full, :test_fixtures} ->
        Mix.raise("qlover test fixtures or helpers changed; run full coverage")

      {:full, :unattributed} ->
        Mix.raise("qlover cannot attribute test changes; run full coverage")

      {:incremental, %{prove: [], test_changed: false}} ->
        snapshot =
          build_snapshot(
            settings,
            {baseline.tests, baseline.librefs, baseline.beams},
            current,
            gate
          )

        write_snapshot_if_changed!(settings, baseline, snapshot)
        Mix.shell().info("No beam changes since baseline; coverage holds.")
        :ok

      {:incremental, %{prove: [], test_changed: true}} ->
        if File.exists?(settings.export_path) or File.exists?(settings.expansion_export_path) do
          snapshot =
            build_snapshot(
              settings,
              {baseline.tests, baseline.librefs, baseline.beams},
              current,
              gate
            )

          write_snapshot_if_changed!(settings, baseline, snapshot)
          _ = File.rm(settings.export_path)
          _ = File.rm(settings.expansion_export_path)
          Mix.shell().info("Test changes need no fresh proof; coverage holds.")
          :ok
        else
          Mix.raise(
            "cannot import coverage export #{settings.export_path}: no fresh export produced; " <>
              "the stale subset produced no usable export for the changed beams, run full coverage"
          )
        end

      {:incremental, %{prove: prove}} ->
        gate_proven!(settings, baseline, current, gate, prove)
    end
  end

  defp gate_attributed!(settings, baseline, current, gate) do
    case attribution_plan(settings, baseline, current) do
      {:full, reason} ->
        Mix.raise("qlover requires a full run: #{inspect(reason)}")

      {:incremental, plan} ->
        snapshot =
          build_snapshot(
            settings,
            {baseline.tests, baseline.librefs, baseline.beams},
            current,
            gate
          )

        evidence =
          Elixir.Qlover.Native.measure(:evidence_merge, fn ->
            Elixir.Qlover.Coverage.Evidence.advance!(settings, baseline, plan)
          end)

        snapshot = Map.put(snapshot, :attributed, evidence)
        write_snapshot_if_changed!(settings, baseline, snapshot)
        prune_records!(settings, snapshot, current)
        Elixir.Qlover.Coverage.Evidence.gate!(evidence, baseline.attributed.rows)
        Mix.shell().info("qlover holds for attributed coverage.")
        :ok
    end
  end

  @doc false
  def attribution_plan(settings, baseline, current) do
    settings
    |> attribution_input(baseline, current)
    |> Attribution.plan()
  end

  @doc false
  def attribution_plan_with_reasons(settings, baseline, current) do
    settings
    |> attribution_input(baseline, current)
    |> Attribution.explain_plan()
  end

  defp attribution_input(settings, baseline, current) do
    current_tests = test_hashes(settings)
    records = decoded_records(settings, current_tests)
    fresh_by_rel = Map.new(records, &{&1.path, &1})
    beam_changed = changed_beams(baseline.beams, current)
    previous_sources = Map.get(Map.get(baseline, :attributed) || %{}, :sources, %{})
    current_sources = Elixir.Qlover.Coverage.Evidence.sources(settings.compile_path)

    %{
      beam_changed: beam_changed,
      beam_deleted: deleted_beams(baseline.beams, current),
      current_beams: current,
      baseline_tests: baseline.tests,
      current_tests: current_tests,
      union_refs: Attribution.union_refs(baseline.tests, fresh_by_rel, current_tests),
      lib_edges: baseline.librefs,
      fresh_lib_edges:
        Attribution.filter_lib_edges(Attribution.group_by_defined(records), current),
      compiled_dirs: expand_dirs(settings.elixirc_paths, settings.project_root),
      project_root: settings.project_root,
      attributed: Map.get(baseline, :attributed) != nil,
      source_map_drift:
        Enum.any?(current_sources, fn {beam, hash} ->
          previous_sources[beam] != hash and beam not in beam_changed
        end),
      dependency_unchanged:
        Map.get(Map.get(baseline, :attributed) || %{}, :dependencies) ==
          Elixir.Qlover.Coverage.Evidence.dependencies(settings.compile_path),
      runtime_owners:
        Elixir.Qlover.Coverage.Evidence.owners(
          Map.get(baseline, :attributed),
          beam_changed
        )
    }
  end

  @doc false
  def test_hashes(settings) do
    Elixir.Qlover.Inputs.fetch({:tests, settings.test_paths, settings.project_root}, fn ->
      Elixir.Qlover.Native.measure(:test_hashes, fn ->
        Elixir.Qlover.Native.test_hashes(settings, fn ->
          settings
          |> list_test_files()
          |> Map.new(fn abs -> {relativize(abs, settings.project_root), hash_file!(abs)} end)
        end)
      end)
    end)
  end

  @doc false
  def read_baseline!(path) do
    case File.read(path) do
      {:ok, contents} -> decode_baseline!(path, contents)
      {:error, _reason} -> Mix.raise("qlover baseline #{path} is missing; run full coverage")
    end
  end

  @doc false
  def load_baseline(settings, options \\ []) do
    with {:ok, contents} <- File.read(settings.baseline),
         {:ok, baseline} <- decode_baseline(contents) do
      {:ok, baseline}
    else
      _error -> fetch_cached_baseline(settings, Keyword.get(options, :persist, true))
    end
  end

  defp fetch_cached_baseline(settings, persist?) do
    with dir when is_binary(dir) <- settings.cache_dir,
         current <- beam_hashes(settings.compile_path),
         gate <- gate_hash(settings.gate_paths, settings.project_root),
         tests <- test_hashes(settings),
         keys <- [
           Attribution.cache_key(%{
             beams: current,
             gate: gate,
             tests: tests,
             sources: Elixir.Qlover.Coverage.Evidence.sources(settings.compile_path),
             dependencies: Elixir.Qlover.Coverage.Evidence.dependencies(settings.compile_path)
           }),
           Attribution.cache_key(%{beams: current, gate: gate, tests: tests})
         ],
         {:ok, baseline} <- find_cached_baseline(dir, keys) do
      if persist?, do: persist_baseline!(settings, baseline)
      {:ok, baseline}
    else
      _error -> :error
    end
  end

  defp find_cached_baseline(dir, keys) do
    Enum.find_value(keys, :error, fn key ->
      with {:ok, contents} <- File.read(cache_baseline_path(dir, key)),
           {:ok, baseline} <- decode_baseline(contents) do
        {:ok, baseline}
      else
        _ -> nil
      end
    end)
  end

  defp load_baseline!(settings) do
    case load_baseline(settings) do
      {:ok, baseline} ->
        baseline

      :error ->
        # Re-read the local file purely for its precise error message
        # (missing vs invalid); the cache already missed.
        read_baseline!(settings.baseline)
    end
  end

  @doc false
  def cache_key(settings) do
    payload = %{
      beams: beam_hashes(settings.compile_path),
      gate: gate_hash(settings.gate_paths, settings.project_root),
      tests: test_hashes(settings)
    }

    case File.read(settings.baseline) do
      {:ok, bytes} ->
        case decode_baseline(bytes) do
          {:ok, %{attributed: _}} ->
            Attribution.cache_key(
              Map.merge(payload, %{
                sources: Elixir.Qlover.Coverage.Evidence.sources(settings.compile_path),
                dependencies: Elixir.Qlover.Coverage.Evidence.dependencies(settings.compile_path)
              })
            )

          _ ->
            Attribution.cache_key(payload)
        end

      _ ->
        Attribution.cache_key(payload)
    end
  end

  @doc false
  def cache_baseline_path(cache_dir, key) do
    Path.join([cache_dir, "baselines", key <> ".term"])
  end

  @doc false
  def cache_refs_dir(cache_dir) do
    Path.join(cache_dir, "refs")
  end

  @doc false
  def beam_hashes(directory) do
    Elixir.Qlover.Inputs.fetch({:beams, directory}, fn ->
      directory |> list_beams!() |> Map.new(&{&1, beam_hash!(directory, &1)})
    end)
  end

  @doc false
  def stable_chunks(chunks) do
    # Only cover-relevant chunks participate in change detection. Dbgi,
    # Docs, CInf, ExCk, and Line embed absolute source paths, option
    # snapshots, or nondeterministically ordered metadata, so identical
    # sources built in different directories hash differently if they are
    # included (this is what makes cross-worktree baseline sharing
    # possible at all). Excluding them is sound: none affect execution,
    # and line numbers are mere labels for the legacy aggregate gate.
    # Attributed snapshots retain a *separate* source-map fingerprint, so
    # pure line shifts cannot silently relabel cached per-file hits. Other
    # volatile chunks merely cost a fresh proof, never a false pass.
    chunks
    |> Enum.reject(fn {name, _binary} ->
      name in [~c"ExCk", ~c"Dbgi", ~c"Docs", ~c"CInf", ~c"Line"]
    end)
    |> Enum.sort_by(fn {name, _binary} -> name end)
  end

  @doc false
  def gate_hash(roots, relative_to \\ nil) do
    Elixir.Qlover.Inputs.fetch({:gate, roots, relative_to}, fn ->
      root = relative_to || File.cwd!()

      payload =
        roots
        |> Enum.flat_map(fn r -> [r | Path.wildcard(r <> "/**/*")] end)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(fn file -> {Path.relative_to(file, root), hash_file!(file)} end)
        |> Enum.sort()
        |> Enum.uniq()

      :crypto.hash(:sha256, :erlang.term_to_binary(payload)) |> Base.encode16(case: :lower)
    end)
  end

  @doc false
  def changed_beams(baseline, current) do
    for({beam, sha} <- current, Map.get(baseline, beam) != sha, do: beam) |> Enum.sort()
  end

  @doc false
  def deleted_beams(baseline, current) do
    for({beam, _sha} <- baseline, not is_map_key(current, beam), do: beam)
    |> Enum.map(&Attribution.beam_module_string/1)
    |> Enum.sort()
  end

  @doc false
  def beam_module(beam) do
    beam |> Path.basename(".beam") |> String.to_atom()
  end

  @doc false
  def ensure_cover!(directory) do
    Mix.ensure_application!(:tools)
    _ = :cover.start()

    beams = directory |> list_beams!() |> Enum.map(&String.to_charlist(Path.join(directory, &1)))
    beams |> :cover.compile_beam() |> List.wrap() |> enforce_beam_results!()
  end

  @doc false
  def import_export!(path) do
    # Note: unreadable files return {:error, reason} here, but corrupt
    # files take down the cover server instead (an exit, on OTP 29). Both
    # fail closed: the former with a message, the latter by crashing the
    # task before anything is trusted or snapshotted.
    case :cover.import(String.to_charlist(path)) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "cannot import coverage export #{path}: #{inspect(reason)}; " <>
            "the stale subset produced no usable export for the changed beams, run full coverage"
        )
    end
  end

  @doc false
  def module_line_totals(module) do
    Mix.ensure_application!(:tools)

    case :cover.analyse(module, :coverage, :line) do
      {:ok, entries} ->
        sum_lines(entries)

      {:error, reason} ->
        Mix.raise("cannot analyse coverage for #{inspect(module)}: #{inspect(reason)}")
    end
  end

  @doc false
  def enforce_full_coverage!(results) do
    failures = Enum.filter(results, fn {_module, {covered, total}} -> covered != total end)

    if failures == [] do
      :ok
    else
      Mix.raise("qlover coverage is incomplete:\n" <> format_failures(failures))
    end
  end

  @doc false
  def write_module_html!(modules, output) do
    File.mkdir_p!(output)

    modules
    |> Enum.map(fn module ->
      :cover.async_analyse_to_file(module, html_path(output, module), [:html])
    end)
    |> Enum.each(&await_cover/1)

    :ok
  end

  @doc false
  def quiet_cover(fun) do
    # cover announces "Analysis includes data from imported files" through the
    # group leader of its server process, once for every analysed module. A
    # gate over an imported export analyses every proven module, so that
    # notice floods the output. Point the server's group leader at a
    # throwaway IO server for the duration; the server spawns its analysis
    # workers from itself, so they inherit the silent leader.
    server = Process.whereis(:cover_server)
    {:group_leader, original} = Process.info(server, :group_leader)
    sink = spawn(fn -> cover_sink() end)

    try do
      :erlang.group_leader(sink, server)
      fun.()
    after
      :erlang.group_leader(original, server)
      send(sink, :stop)
    end
  end

  defp cover_sink do
    receive do
      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, :ok})
        cover_sink()

      :stop ->
        :ok
    end
  end

  defp gate_proven!(settings, baseline, current, gate, prove) do
    ensure_cover!(settings.compile_path)
    imported = import_fresh_exports!(settings)

    if imported == 0 do
      Mix.raise(
        "cannot import coverage export #{settings.export_path}: no fresh export produced; " <>
          "the stale subset produced no usable export for the changed beams, run full coverage"
      )
    end

    results = quiet_cover(fn -> Enum.map(prove, &cover_result/1) end)
    enforce_full_coverage!(results)
    quiet_cover(fn -> write_module_html!(Enum.map(results, &elem(&1, 0)), settings.output) end)

    snapshot =
      build_snapshot(settings, {baseline.tests, baseline.librefs, baseline.beams}, current, gate)

    persist_baseline!(settings, snapshot)
    prune_records!(settings, snapshot, current)
    _ = File.rm(settings.export_path)
    _ = File.rm(settings.expansion_export_path)
    Mix.shell().info("qlover holds for #{length(prove)} proven beam(s).")
    :ok
  end

  defp import_fresh_exports!(settings) do
    paths =
      [settings.export_path, settings.expansion_export_path]
      |> Enum.filter(&File.exists?/1)

    Enum.each(paths, &import_export!/1)
    length(paths)
  end

  defp cover_result(beam) do
    module = beam_module(beam)
    {module, module_line_totals(module)}
  end

  defp build_snapshot(settings, {prior_tests, prior_librefs, prior_beams}, current, gate) do
    current_tests = test_hashes(settings)
    records = decoded_records(settings, current_tests)
    fresh_by_rel = Map.new(records, &{&1.path, &1})

    changed_mods =
      prior_beams |> changed_beams(current) |> Enum.map(&Attribution.beam_module_string/1)

    snapshot = %{
      vsn: @vsn,
      beams: current,
      gate: gate,
      tests: Attribution.snapshot_tests(current_tests, prior_tests, fresh_by_rel),
      librefs:
        Attribution.snapshot_librefs(
          prior_librefs,
          Attribution.filter_lib_edges(Attribution.group_by_defined(records), current),
          changed_mods
        )
    }

    # Counts are optional metadata, independent of the coverage proof. Keep
    # them in the shared baseline so unchanged checkouts can report savings.
    counts = settings.test_counts || prior_counts(settings.baseline)
    if counts, do: Map.put(snapshot, :test_counts, counts), else: snapshot
  end

  defp prior_counts(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, baseline} <- decode_baseline(bytes) do
      Map.get(baseline, :test_counts)
    else
      _ -> nil
    end
  end

  defp read_prior_baseline(settings) do
    with {:ok, contents} <- File.read(settings.baseline),
         {:ok, baseline} <- decode_baseline(contents) do
      {baseline.tests, baseline.librefs, baseline.beams}
    else
      _error -> {%{}, %{}, %{}}
    end
  end

  defp write_snapshot_if_changed!(settings, baseline, snapshot) do
    if snapshot != baseline do
      persist_baseline!(settings, snapshot)
    else
      :ok
    end
  end

  defp persist_baseline!(settings, snapshot) do
    Elixir.Qlover.Native.measure(:baseline_write, fn ->
      write_baseline_file!(settings.baseline, snapshot)
    end)

    store_cached_baseline(settings, snapshot)
    sync_cached_records(settings)
    :ok
  end

  defp store_cached_baseline(%{cache_dir: nil}, _snapshot), do: :ok

  defp store_cached_baseline(settings, snapshot) do
    payload = %{
      beams: snapshot.beams,
      gate: snapshot.gate,
      tests: snapshot.tests
    }

    key =
      if evidence = Map.get(snapshot, :attributed) do
        Attribution.cache_key(
          Map.merge(payload, %{sources: evidence.sources, dependencies: evidence.dependencies})
        )
      else
        Attribution.cache_key(payload)
      end

    path = cache_baseline_path(settings.cache_dir, key)
    File.mkdir_p!(Path.dirname(path))
    write_baseline_file!(path, snapshot)
    :ok
  rescue
    _error -> :ok
  end

  defp sync_cached_records(%{cache_dir: nil}), do: :ok

  defp sync_cached_records(settings) do
    dest = cache_refs_dir(settings.cache_dir)
    File.mkdir_p!(dest)

    case File.ls(settings.refs_dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          if String.ends_with?(entry, ".term") do
            path = Path.join(dest, entry)
            temp = path <> ".#{System.pid()}-#{System.unique_integer([:positive])}.tmp"

            if File.cp(Path.join(settings.refs_dir, entry), temp) == :ok do
              File.rename(temp, path)
            end
          end
        end)

      {:error, _reason} ->
        :ok
    end

    :ok
  rescue
    _error -> :ok
  end

  defp warn_unknown_refs(tests) do
    unknown = Attribution.unknown_files(tests)

    concrete? =
      Enum.any?(tests, fn {_rel, %{modules: modules}} -> is_list(modules) and modules != [] end)

    if unknown != [] and concrete? do
      Mix.shell().info(
        "qlover has no reference data for #{length(unknown)} test file(s); " <>
          "test edits will fall back to full runs until a traced full run refreshes them. " <>
          "Enable Qlover.Tracer (see Mix.Tasks.Qlover docs) to keep attribution incremental."
      )
    else
      :ok
    end
  end

  defp test_identity?(baseline_tests, current_tests) do
    Map.new(baseline_tests, fn {rel, entry} -> {rel, entry.sha} end) == current_tests
  end

  defp list_test_files(settings) do
    settings.test_paths
    |> Enum.flat_map(fn root ->
      expanded = expand_root(root, settings.project_root)
      [expanded | Path.wildcard(expanded <> "/**/*")]
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.uniq()
  end

  defp expand_root(root, project_root) do
    if Path.type(root) == :absolute, do: root, else: Path.join(project_root, root)
  end

  defp expand_dirs(roots, project_root) do
    roots |> Enum.map(&expand_root(&1, project_root)) |> Enum.sort() |> Enum.uniq()
  end

  defp relativize(abs, project_root) do
    Path.relative_to(abs, project_root)
  end

  defp decoded_records(settings, current_tests) do
    Elixir.Qlover.Native.measure(:reference_records, fn ->
      local = list_record_entries(settings.refs_dir)
      cache = list_cache_record_entries(settings)
      Attribution.merge_records(local, cache, current_tests)
    end)
  end

  defp list_cache_record_entries(%{cache_dir: nil}), do: []

  defp list_cache_record_entries(settings) do
    list_record_entries(cache_refs_dir(settings.cache_dir))
  end

  defp list_record_entries(refs_dir) do
    Elixir.Qlover.Inputs.fetch({:records, refs_dir}, fn ->
      Elixir.Qlover.Native.records(refs_dir, fn -> read_record_entries(refs_dir) end)
    end)
  end

  defp read_record_entries(refs_dir) do
    case File.ls(refs_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".term"))
        |> Enum.sort()
        |> Enum.map(&{&1, read_record(refs_dir, &1)})

      {:error, _reason} ->
        []
    end
  end

  defp read_record(refs_dir, entry) do
    with {:ok, contents} <- File.read(Path.join(refs_dir, entry)),
         {:ok, record} <- Attribution.decode_record(contents) do
      {:ok, record}
    else
      _error -> :error
    end
  end

  defp prune_records!(settings, snapshot, current) do
    entries = list_record_entries(settings.refs_dir)
    current_files = MapSet.new(Map.keys(snapshot.tests))

    beamed =
      MapSet.new(current, fn {beam, _sha} -> Attribution.beam_module_string(beam) end)

    for filename <- Attribution.prune_records(entries, current_files, beamed) do
      File.rm(Path.join(settings.refs_dir, filename))
    end

    :ok
  end

  defp decode_baseline!(path, contents) do
    case decode_baseline(contents) do
      {:ok, baseline} -> baseline
      :error -> Mix.raise("qlover baseline #{path} is invalid; run full coverage")
    end
  end

  defp decode_baseline(contents) do
    # Content-addressed even within a request: a test replacing the baseline
    # must never inherit a validation result for the previous bytes.
    validators = [__MODULE__, Attribution, Elixir.Qlover.Coverage.Evidence, Qlover.TestCounts]
    identity = Enum.map(validators, & &1.module_info(:md5))
    key = {:baseline, :crypto.hash(:sha256, contents), identity}
    Elixir.Qlover.Inputs.fetch(key, fn -> validate_baseline(contents) end)
  end

  defp validate_baseline(contents) do
    case decode_term(contents) do
      %{vsn: @vsn, beams: beams, gate: gate, tests: tests, librefs: librefs} = baseline
      when is_map(beams) and is_binary(gate) ->
        if Attribution.valid_tests?(tests) and Attribution.valid_librefs?(librefs) and
             Elixir.Qlover.Coverage.Evidence.valid?(Map.get(baseline, :attributed)) and
             Qlover.TestCounts.valid_inventory?(Map.get(baseline, :test_counts, %{})) do
          {:ok, baseline}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp decode_term(contents) do
    :erlang.binary_to_term(contents)
  rescue
    _error -> :invalid
  end

  defp list_beams!(directory) do
    case File.ls(directory) do
      {:ok, entries} -> entries |> Enum.filter(&String.ends_with?(&1, ".beam")) |> Enum.sort()
      {:error, _reason} -> Mix.raise("cannot list compiled beams in #{directory}")
    end
  end

  defp beam_hash!(directory, beam) do
    path = Path.join(directory, beam)

    case beam_chunks(path) do
      {:ok, chunks} ->
        :crypto.hash(:sha256, :erlang.term_to_binary(stable_chunks(chunks)))
        |> Base.encode16(case: :lower)

      :error ->
        hash_file!(path)
    end
  end

  defp beam_chunks(path) do
    # Reading once avoids beam_lib's file-server round trips for every chunk.
    case :beam_lib.all_chunks(File.read!(path)) do
      {:ok, _module, chunks} -> {:ok, chunks}
      _error -> :error
    end
  end

  defp hash_file!(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end

  defp enforce_beam_results!(results) do
    failures = for {:error, reason} <- results, do: reason

    if failures == [] do
      :ok
    else
      Mix.raise("cover compilation failed: #{inspect(failures)}")
    end
  end

  defp sum_lines(entries) do
    by_line =
      Enum.reduce(entries, %{}, fn {{_module, line}, {covered, _}}, acc ->
        if line == 0, do: acc, else: Map.put(acc, line, Map.get(acc, line, false) or covered > 0)
      end)

    {Enum.count(by_line, &elem(&1, 1)), map_size(by_line)}
  end

  defp format_failures(failures) do
    Enum.map_join(failures, "\n", fn {module, {covered, total}} ->
      "  #{inspect(module)}: #{covered}/#{total} lines"
    end)
  end

  defp html_path(output, module) do
    output |> Path.join("#{module}.html") |> String.to_charlist()
  end

  defp await_cover(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end

  defp write_baseline_file!(path, baseline) do
    File.mkdir_p!(Path.dirname(path))
    temp = path <> ".#{System.pid()}-#{System.unique_integer([:positive])}.tmp"
    File.write!(temp, :erlang.term_to_binary(baseline, [{:compressed, 1}]))
    File.rename!(temp, path)
  end
end
