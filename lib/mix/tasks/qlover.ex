defmodule Mix.Tasks.Qlover do
  @shortdoc "Gates incremental coverage from stale test runs"

  @moduledoc """
  Proves 100% line coverage from a stale subset plus the full-run baseline.

      mix qlover --eligible
      mix test --stale --cover --export-coverage .qlover_fresh
      mix qlover
      mix qlover --write-baseline

  The baseline records beam hashes from the last green full run, a hash of
  the non-test gate inputs (`priv/repo`, `config`, `mix.exs`, `mix.lock`),
  and a snapshot of the test files (content hashes plus traced module
  references). A stale run satisfies the gate when the non-test inputs are
  unchanged: every test that references a changed beam reruns under
  `--stale`, so fresh 100% line coverage for the changed beams plus the
  untouched baseline equals a full run. Test-only edits gate incrementally
  too: changed tests re-prove the modules they could have covered (tracked
  via the reference snapshot) instead of forcing a full run. Anything else
  must fall back to `mix test --no-stale --cover`.

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

  Per-test-file attribution needs reference data from the compiler tracer
  (`Qlover.Tracer`). Enable it in the host project:

      # mix.exs
      def project do
        [...,
         elixirc_options: [tracers: [Qlover.Tracer]],
         test_elixirc_options: [tracers: [Qlover.Tracer]]]
      end

  Without tracer data every test edit falls back to the full suite, exactly
  like before — attribution is purely additive and can never pass where the
  old gate would fail.
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
      test_paths: Keyword.get(options, :test_paths, @test_roots),
      elixirc_paths:
        Keyword.get(options, :elixirc_paths, Mix.Project.config()[:elixirc_paths] || ["lib"]),
      project_root: Keyword.get(options, :project_root, File.cwd!()),
      refs_dir: Keyword.get(options, :refs_dir, Qlover.Tracer.default_dir()),
      cache_dir: Keyword.get(options, :cache_dir, default_cache_dir()),
      output: Keyword.get(options, :output, @output_default)
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
    persist_baseline!(settings, snapshot)
    warn_unknown_refs(snapshot.tests)
    prune_records!(settings, snapshot, current)
    Mix.shell().info("Wrote qlover baseline to #{settings.baseline}.")
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

    case attribution_plan(settings, baseline, current) do
      {:full, :test_fixtures} ->
        Mix.raise("qlover test fixtures changed; run full coverage")

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

  @doc false
  def attribution_plan(settings, baseline, current) do
    current_tests = test_hashes(settings)
    records = decoded_records(settings, current_tests)
    fresh_by_rel = Map.new(records, &{&1.path, &1})

    Attribution.plan(%{
      beam_changed: changed_beams(baseline.beams, current),
      beam_deleted: deleted_beams(baseline.beams, current),
      current_beams: current,
      baseline_tests: baseline.tests,
      current_tests: current_tests,
      union_refs: Attribution.union_refs(baseline.tests, fresh_by_rel, current_tests),
      lib_edges: baseline.librefs,
      fresh_lib_edges:
        Attribution.filter_lib_edges(Attribution.group_by_defined(records), current),
      compiled_dirs: expand_dirs(settings.elixirc_paths, settings.project_root),
      project_root: settings.project_root
    })
  end

  @doc false
  def test_hashes(settings) do
    settings
    |> list_test_files()
    |> Map.new(fn abs -> {relativize(abs, settings.project_root), hash_file!(abs)} end)
  end

  @doc false
  def read_baseline!(path) do
    case File.read(path) do
      {:ok, contents} -> decode_baseline!(path, contents)
      {:error, _reason} -> Mix.raise("qlover baseline #{path} is missing; run full coverage")
    end
  end

  @doc false
  def load_baseline(settings) do
    with {:ok, contents} <- File.read(settings.baseline),
         {:ok, baseline} <- decode_baseline(contents) do
      {:ok, baseline}
    else
      _error -> fetch_cached_baseline(settings)
    end
  end

  defp fetch_cached_baseline(settings) do
    with dir when is_binary(dir) <- settings.cache_dir,
         current <- beam_hashes(settings.compile_path),
         gate <- gate_hash(settings.gate_paths, settings.project_root),
         tests <- test_hashes(settings),
         key <- Attribution.cache_key(%{beams: current, gate: gate, tests: tests}),
         {:ok, contents} <- File.read(cache_baseline_path(dir, key)),
         {:ok, baseline} <- decode_baseline(contents) do
      persist_baseline!(settings, baseline)
      {:ok, baseline}
    else
      _error -> :error
    end
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
    Attribution.cache_key(%{
      beams: beam_hashes(settings.compile_path),
      gate: gate_hash(settings.gate_paths, settings.project_root),
      tests: test_hashes(settings)
    })
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
    directory |> list_beams!() |> Map.new(&{&1, beam_hash!(directory, &1)})
  end

  @doc false
  def stable_chunks(chunks) do
    # Only cover-relevant chunks participate in change detection. Dbgi,
    # Docs, CInf, ExCk, and Line embed absolute source paths, option
    # snapshots, or nondeterministically ordered metadata, so identical
    # sources built in different directories hash differently if they are
    # included (this is what makes cross-worktree baseline sharing
    # possible at all). Excluding them is sound: none affect execution,
    # and line numbers are mere labels — identical Code means identical
    # executable structure, so an unchanged suite covers it exactly as
    # before (pure line shifts need no fresh proof). Any other volatile
    # chunk merely costs a fresh 100% proof, never a false pass.
    chunks
    |> Enum.reject(fn {name, _binary} ->
      name in [~c"ExCk", ~c"Dbgi", ~c"Docs", ~c"CInf", ~c"Line"]
    end)
    |> Enum.sort_by(fn {name, _binary} -> name end)
  end

  @doc false
  def gate_hash(roots, relative_to \\ nil) do
    root = relative_to || File.cwd!()

    payload =
      roots
      |> Enum.flat_map(fn r -> [r | Path.wildcard(r <> "/**/*")] end)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn file -> {Path.relative_to(file, root), hash_file!(file)} end)
      |> Enum.sort()
      |> Enum.uniq()

    :crypto.hash(:sha256, :erlang.term_to_binary(payload)) |> Base.encode16(case: :lower)
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

  defp gate_proven!(settings, baseline, current, gate, prove) do
    ensure_cover!(settings.compile_path)
    imported = import_fresh_exports!(settings)

    if imported == 0 do
      Mix.raise(
        "cannot import coverage export #{settings.export_path}: no fresh export produced; " <>
          "the stale subset produced no usable export for the changed beams, run full coverage"
      )
    end

    results = Enum.map(prove, &cover_result/1)
    enforce_full_coverage!(results)
    write_module_html!(Enum.map(results, &elem(&1, 0)), settings.output)

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

    %{
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
    write_baseline_file!(settings.baseline, snapshot)
    store_cached_baseline(settings, snapshot)
    sync_cached_records(settings)
    :ok
  end

  defp store_cached_baseline(%{cache_dir: nil}, _snapshot), do: :ok

  defp store_cached_baseline(settings, snapshot) do
    key =
      Attribution.cache_key(%{
        beams: snapshot.beams,
        gate: snapshot.gate,
        tests: snapshot.tests
      })

    path = cache_baseline_path(settings.cache_dir, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(snapshot, [:compressed]))
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
            File.cp(
              Path.join(settings.refs_dir, entry),
              Path.join(dest, entry)
            )
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
    local = list_record_entries(settings.refs_dir)
    cache = list_cache_record_entries(settings)
    Attribution.merge_records(local, cache, current_tests)
  end

  defp list_cache_record_entries(%{cache_dir: nil}), do: []

  defp list_cache_record_entries(settings) do
    list_record_entries(cache_refs_dir(settings.cache_dir))
  end

  defp list_record_entries(refs_dir) do
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
    case decode_term(contents) do
      %{vsn: @vsn, beams: beams, gate: gate, tests: tests, librefs: librefs} = baseline
      when is_map(beams) and is_binary(gate) ->
        if Attribution.valid_tests?(tests) and Attribution.valid_librefs?(librefs) do
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
    case :beam_lib.all_chunks(String.to_charlist(path)) do
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
    File.write!(path, :erlang.term_to_binary(baseline, [:compressed]))
  end
end
