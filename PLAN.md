# Qlover plan

## Goal

Make `mix test --stale --cover` able to satisfy a 100% line-coverage gate
without rerunning the full suite — i.e. behave like a
`mix test --cover --stale` plugin that runs tests *and* gathers coverage at
the same time.

Accepted when: changing one `lib` module and running the stale subset +
`mix qlover` passes iff a full run would pass, stays green across repeated
incrementals, and any test/config/migration change (or missing baseline)
falls back to the full suite instead of guessing.

## Non-goals

- Branch/path coverage: the backend is line coverage, same as
  `mix test --cover`.
- Remote/distributed cover nodes: local-only, like the Mix default.

## Approach

Partition the gate; never merge line counts across code versions.

1. **Baseline** (`cover/.qlover_baseline`): beam hashes from the last green
   full run, a combined hash of the non-test gate inputs (`priv/repo`,
   `config`, `mix.exs`, `mix.lock`), per-test-file content hashes, and the
   traced module reference graph (test files plus lib-to-lib edges).
2. **Eligibility**: baseline must exist, non-test inputs must be
   byte-identical, and test files must be unchanged. Otherwise run the
   full suite (safe default; an eligibility failure can never pass the
   gate).
3. **Stale run**: `mix test --stale --cover --export-coverage .qlover_fresh`
   executes every test referencing changed code and exports the subset.
   When only test files changed, a focused expansion run executes every
   test referencing an affected module and exports a second fresh subset.
4. **Gate**: beams identical to baseline are trusted. Every new-or-changed
   beam, plus every module a changed test could have covered (old
   references closed transitively over the lib graph), must be 100%
   line-covered in fresh exports alone — same code version throughout, so
   unioning the fresh subsets is sound. On success, refresh changed
   modules' HTML and rewrite the baseline so incrementals chain. Test
   failures abort before gating and never update the baseline.

## Phases

- [x] 1. Core gate task with hermetic tests (this repo: `Mix.Tasks.Qlover`,
  42 tests, green across seeds, 100% line coverage with
  `test_coverage: [summary: [threshold: 100]]`).
- [x] 2. Wrapper script recipe (`cover.sh` shape: eligible → stale+export →
  gate, else full → snapshot) validated end-to-end in this repo: full run
  mints the baseline, repeated incrementals stay green, a covered lib
  change gates via the changed-beam path, an uncovered change fails closed,
  and a test/config change falls back to full. Superseded by `mix
  test.qlover`, which implements the same flow in one command (20 tests
  with an injected test runner plus a shell-out runner); `cover.sh` now
  delegates to it. An optional host-side alias snippet gives the exact
  `mix test --qlover` spelling (verified in a scratch project).
- [x] 3. Dogfood as a path dependency in one Phoenix app's coverage gate;
  confirm incremental/full agreement on real lib changes. Validated in a
  scratch clone of labqoat (976 beams, 2836 tests, threshold-100 suite,
  isolated postgres): full→baseline, no-change chaining, covered lib
  change passes, uncovered lib change fails naming the module with full-run
  red agreement, comment-only test edit gates incrementally, gutted shared
  coverage fails closed, new/deleted test files and support changes behave,
  config changes fall back to full. See follow-up entry below.
- [x] 4. Per-test-file attribution (compiler-tracer reference graph with
  transitive lib closure + focused expansion runs and fresh-export union)
  so test edits gate incrementally instead of forcing full runs.
  Non-code fixture changes and tests without reference data still fall
  back to full, fail-closed.
- [x] 5. Hex publish readiness (`qlover` package, `mix qlover` task, docs):
  package metadata (links: `https://github.com/qforge-dev/qlover`),
  `cover.sh` in package files, `README`/`CHANGELOG`/`LICENSE` (Apache-2.0),
  `ex_doc` config, `mix hex.build` passes. Publish itself
  (`mix hex.publish`) still to run.

## Architecture

```
mix qlover --eligible ── no ──▶ mix test --no-stale --cover ──▶ mix qlover --write-baseline
        │ yes                                                              (baseline)
        ▼
mix test --stale --cover --export-coverage .qlover_fresh ──▶ mix qlover ──▶ pass + new baseline
        (tests must pass first)                              (changed beams 100%? else fail)
```

`mix test.qlover` owns a third path between those two: when only test
files changed and reference data is available, it runs the stale subset
plus a focused expansion run (`mix test <affected files> --cover
--export-coverage .qlover_expansion`) and gates the union. The manual
three-step flow stays conservative: `--eligible` still requires
byte-identical test files, so test edits fall back to full there.

- `Mix.Tasks.Qlover`: the whole mechanism. Modes: `--eligible` (fast,
  no compilation, no cover), `--write-baseline` (snapshot after full),
  default (gate). Path-injectable options (`baseline:`,
  `export_path:`, `expansion_export_path:`, `compile_path:`,
  `gate_paths:`, `test_paths:`, `project_root:`, `refs_dir:`, `output:`)
  keep every branch unit testable with fixture beams compiled to tmp dirs.
- `Qlover.Tracer`: compiler tracer recording test-file → module edges
  (remote calls/macros, imports, aliases, struct expansions) plus
  lib-module definers, flushed atomically per file on `:stop` into
  content-hashed records. Enabled with `elixirc_options` (lib) plus
  `test_elixirc_options` (test files are required separately by `mix
  test`). Never breaks compilation; every failure degrades to a full
  fallback, never to a pass.
- `Qlover.Attribution`: pure planning over plain data (change detection,
  transitive closure with cycle safety, expansion selection, snapshot
  merging, record pruning, baseline validation).
- Scratch exports (`cover/.qlover_fresh.coverdata` for the stale run,
  `cover/.qlover_expansion.coverdata` for the expansion run) are
  import-only inputs for the gate and must be deleted afterwards, or a
  later `mix test.coverage` would union a stale partial into a full
  report.
- `cover/` keeps per-module HTML coherent: unchanged modules keep baseline
  HTML (source identical), changed modules are regenerated on pass.

## Soundness contract

- Trusts `--stale` completeness: every test referencing a changed beam
  reruns. The gate re-derives "changed" from beam hashes independently of
  the stale manifest, so manifest timing cannot fool it.
- Changed beams are judged on fresh data only; baseline line data for them
  is discarded (never imported), so shifted line numbers cannot leak.
- Unchanged beams are trusted only together with byte-identical
  non-test inputs and unattributed test files, which rules out the masking
  case (a changed test silently keeping its old contribution). Only
  decreases need fresh proof: a changed test's old references (pinned in
  the baseline snapshot) bound what it could have covered, closed
  transitively over lib edges; new files only add coverage.
- Fresh-export union is sound only within one code version: the gate never
  imports the baseline export, and all fresh exports come from runs of the
  current tree, so identical beams mean identical line numbers.
- Tracer completeness is a trust assumption in the same class as `--stale`
  completeness: dynamically dispatched calls, protocol implementations
  (covered without naming their modules), and externals outside `test/`
  that are not gate inputs are invisible to static references. Gaps degrade
  to full fallbacks or fail-closed rejections, never to passes — except a
  changed test silently dropping dynamically-dispatched coverage, the one
  documented residual, which is why the assumption is stated, not hidden.
- Fail-closed: missing/invalid baseline, missing export with pending
  changes, unattributable test changes, fixture changes, per-module
  cover-compile errors, and unanalysable modules all raise instead of
  passing.
- Deterministic beams assumed for change detection (same source + toolchain
  ⇒ same bytes); a spurious hash change only costs a fresh 100% proof,
  never a false pass.

## Risks and open questions

- Consolidated protocols: the gate cover-compiles plain ebin beams and
  ignores the consolidation swap upstream performs. Correct for counting
  (the instrumented beam is what gets loaded) but unproven on a
  protocol-heavy suite — phase 3 must confirm.
- ExUnit `--stale` manifest staleness vs beam hashes: hashes subsume mtime
  logic for compiled code; externals outside `test/` are not tracked and
  fall back to full only if they live under gate inputs.
- `mix test.coverage` interplay: qlover scratch files must never linger in
  `cover/`; the task deletes the exports after gating and removes leftovers
  before each run, with `mix test.qlover` owning the full flow.
- Reference staleness: tracer records are content-keyed (sha-pinned), so a
  stale record can never be mistaken for fresh data; baseline snapshots
  carry old references only for byte-identical files. No Mix or ExUnit
  manifests are read — the design deliberately avoids coupling to Mix
  internals, which would silently break across Elixir upgrades.
- Beam byte-stability across histories: on Elixir 1.20 with this
  codebase, identical sources rebuild to byte-different beams for some
  modules (observed 4–800 per rebuild, varying run to run). Root-caused to
  the `ExCk` chunk (`{:elixir_checker_v8, ...}`): same decoded term,
  different map-key encoding order. Qlover now hashes stable chunks only
  (everything but `ExCk`), which collapsed a forced-rebuild diff from
  hundreds to ~2 modules end-to-end. Any residual wobble only ever costs
  a fresh 100% proof, never a false pass, per the contract.

## Initial work

Built and verified 2026-09-17 (ported from the labqoat spike, same
behavior, 15/15 tests green across seeds 0/42/12345/99999):

- `lib/mix/tasks/qlover.ex` — `Mix.Tasks.Qlover` (full code in Appendix A).
- `test/task_test.exs` — `Qlover.TaskTest`: hermetic fixture beams
  compiled to tmp dirs, real `:cover` sessions scoped to fixture modules
  only (never `:cover.stop/0`, so tests are safe inside a suite already
  running under cover), `async: false` for the global cover server.
- Key behaviors pinned by tests: baseline roundtrip + eligibility,
  missing/corrupt/version-mismatched baselines, gate-input drift,
  no-change pass without export, changed-beam pass (HTML written, baseline
  updated), partial-coverage rejection (no HTML, no baseline update),
  missing export, non-cover-compiled modules, beams without abstract code,
  missing beam dir, pure beam-diff/module-mapping/enforcement units,
  default settings.
- Findings baked in during the spike: `Path.wildcard` brace expansion is
  unusable (use explicit `[root | wildcard(root <> "/**/*")]`);
  `:cover.compile_beam` *raises* on non-beam garbage but returns
  per-module errors for beams without abstract code; module-level analysis
  counts raw bumps and disagrees with the Mix line summary (gate uses line
  level); `mix test --stale --cover --export-coverage` works through the
  `mix test` alias and even writes an (empty) export on `--dry-run`.

## Follow-up work (same day)

- Hardened `Mix.Tasks.Qlover`: rejects `--eligible` + `--write-baseline`
  together, deletes the scratch export on successful gates, prunes
  deleted beams from the baseline, documents `--baseline`/`--export`,
  non-raising `eligible?/1`, clearer no-export error.
  Simplified `ensure_cover!/1` to `_ = :cover.start()` so both old
  branches collapse (also closes the one uncovered line).
- Tests grew 15 → 33: single-arity entrypoints, flag mutual exclusion,
  gate-input drift during `gate!/1`, export cleanup, deleted-beam pruning,
  `eligible?/1` health, and the `mix test.qlover` suite (arg splitting,
  stale/full selection, passthrough, fail-closed runners, export-name
  derivation, shell-out exit codes).
  Suite gates itself at 100% (`test_coverage` threshold 100, fixture
  modules `~r/^QloverFix/` ignored).
- Added `mix test.qlover`: one command that runs stale+gate when eligible
  and full+snapshot otherwise (first runs announce themselves), forwarding
  extra args to `mix test` and leaving plain `mix test` untouched. It
  shells out to `mix test` deliberately: test failures signal via
  `System.at_exit`, so only the subprocess exit code is trustworthy.
  `cover.sh` is now a thin `exec` wrapper around it.
- Added executable `cover.sh` (eligible → stale+export → gate, else
  full → snapshot; trap cleanup) and validated end-to-end in this repo:
  full mints baseline, repeated incrementals stay green, covered lib
  change holds via changed-beam path, uncovered change fails closed
  without updating the baseline (including the no-stale-tests →
  no-export case), test edits fall back to full, and a corrupted
  intermediate state self-heals through the changed-beam path.
- Hex readiness: `ex_doc`, package files (including `cover.sh`),
  `README`/`CHANGELOG`/`LICENSE` (Apache-2.0). Note: Appendix A below is
  the *initial* snapshot and predates the hardening above — see `lib/`
  for current code.
- Phase 4 (per-test-file attribution): baseline v2 (`vsn: 2`, non-test
  gate, per-file test hashes, reference snapshot, lib edge graph;
  v1 baselines fail closed to one full re-baseline), `Qlover.Tracer`
  with `:stop`-flushed content-hashed records plus read-modify-write
  union for nested contexts, `Qlover.Attribution` pure planning
  (change/closure/expansion/snapshot/prune/validate), focused expansion
  runs with fresh-export union in `mix test.qlover`, and fail-closed
  fallbacks for fixtures and unattributed tests. Suite at 109 tests,
  100% line coverage enforced on itself. Findings baked in: `inspect/1`
  strips the `Elixir.` prefix while `Atom.to_string/1` keeps it (fixture
  refs must use the latter to match beam filenames); an in-suite corrupt
  `:cover.import` takes down the shared cover server on OTP 29 (returns
  vs exits vary by failure shape), so the corrupt-export test quarantines
  cover state with export/import around the crash to keep self-coverage
  deterministic; `Code.compiler_options/1` returns a map while
  `Code.put_compiler_option/2` returns the previous value; `for..do:`
  needs parens before `|>` or the pipe binds outside the comprehension.
- Phase 4 follow-ups from dogfooding labqoat (scratch clone at clean HEAD,
  isolated postgres on :5434 with its own volume/database, path
  dependency): beam hashing now ignores the `ExCk` chunk (baseline v3;
  forced-rebuild diff collapsed 462→2 modules end to end); expansion runs
  pass `--no-stale` (a host `test` alias injecting `--stale` otherwise
  intersects the explicit file list with a fresh manifest and silently runs
  zero tests) and skip `elixirc_paths` files (requiring compiled support
  would reload plain code over instrumented code and zero its coverage);
  both tasks refuse non-test envs with a clear message (host projects need
  `preferred_envs` entries). Verified: full→baseline, no-change chaining,
  covered lib change passes, uncovered lib change fails naming the module
  with full-run red agreement, comment-only test edit gates incrementally,
  deleted sole-covering test fails naming it with full-run red agreement,
  new/support files pass, config changes fall back to full. One transient
  "No stale tests" on a real lib change was observed once, fail-closed,
  never reproduced since; out-of-band test runs desyncing ExUnit's
  manifest from the baseline remain the known trigger class.
- Expansion matches referencers against beamed modules only: the baseline
  snapshot keeps tracer noise (`ExUnit.Case`, `Kernel`, `elixir_def`,
  …) that appears in every file, and matching against the raw set widened
  a comment-only test edit to the whole suite. Deleted beams contribute
  their surviving referencers to the expansion (a test still naming a
  deleted module must run to surface the breakage), and pure lib changes
  run no expansion at all (the stale subset already covers every
  referencer). Found via `examples/demo`, which now pins all of this.
- `examples/demo`: runnable 48-test shop (6 modules, 100% gate) plus
  `compare.sh`, which measures full-suite vs `mix test.qlover` across 11
  scenarios (no-change 0 vs 48, small edits 6–22, red cases failing
  identically on 0–3 tests, one-time 48-test warmup shown honestly) and
  exits 1 on any verdict mismatch. Documented with the measured table in
  `README.md`.

## Appendix A — initial implementation

`lib/mix/tasks/qlover.ex` as verified:

```elixir
defmodule Mix.Tasks.Qlover do
  @shortdoc "Gates incremental coverage from stale test runs"

  @moduledoc """
  Proves 100% line coverage from a stale subset plus the full-run baseline.

      mix qlover --eligible
      mix test --stale --cover --export-coverage .qlover_fresh
      mix qlover
      mix qlover --write-baseline

  The baseline records beam hashes from the last green full run and a hash of
  the gate inputs (`test`, `priv/repo`, `config`, `mix.exs`, `mix.lock`). A
  stale run satisfies the gate only when the gate inputs are unchanged: every
  test that references a changed beam reruns under `--stale`, so fresh 100%
  line coverage for the changed beams plus the untouched baseline equals a
  full run. Anything else must fall back to `mix test --no-stale --cover`.
  """

  use Mix.Task

  @vsn 1
  @baseline_default "cover/.qlover_baseline"
  @export_default "cover/.qlover_fresh.coverdata"
  @output_default "cover"
  @gate_roots ["test", "priv/repo", "config", "mix.exs", "mix.lock"]

  @impl Mix.Task
  def run(args), do: run(args, [])

  @doc false
  def run(args, options) do
    {flags, remaining} =
      OptionParser.parse!(args,
        strict: [eligible: :boolean, write_baseline: :boolean, baseline: :string, export: :string]
      )

    if remaining != [] do
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
      compile_path: Keyword.get(options, :compile_path, Mix.Project.compile_path()),
      gate_paths: Keyword.get(options, :gate_paths, @gate_roots),
      output: Keyword.get(options, :output, @output_default)
    }
  end

  @doc false
  def check_eligible!(settings) do
    baseline = read_baseline!(settings.baseline)

    if baseline.gate == gate_hash(settings.gate_paths) do
      Mix.shell().info("Qlover is eligible: gate inputs unchanged.")
      :ok
    else
      Mix.raise("qlover is not eligible: gate inputs changed; run full coverage")
    end
  end

  @doc false
  def write_baseline!(settings) do
    Mix.Task.run("compile")
    write_baseline_file!(settings.baseline, current_baseline(settings))
    Mix.shell().info("Wrote qlover baseline to #{settings.baseline}.")
    :ok
  end

  @doc false
  def gate!(settings) do
    Mix.Task.run("compile")
    baseline = read_baseline!(settings.baseline)
    gate = gate_hash(settings.gate_paths)

    if baseline.gate != gate do
      Mix.raise("gate inputs changed during the stale run; run full coverage")
    end

    current = beam_hashes(settings.compile_path)

    case changed_beams(baseline.beams, current) do
      [] ->
        Mix.shell().info("No beam changes since baseline; coverage holds.")
        :ok

      changed ->
        gate_changed!(settings, changed, current, gate)
    end
  end

  @doc false
  def read_baseline!(path) do
    case File.read(path) do
      {:ok, contents} -> decode_baseline!(path, contents)
      {:error, _reason} -> Mix.raise("qlover baseline #{path} is missing; run full coverage")
    end
  end

  @doc false
  def beam_hashes(directory) do
    directory |> list_beams!() |> Map.new(&{&1, hash_file!(Path.join(directory, &1))})
  end

  @doc false
  def gate_hash(roots) do
    roots
    |> Enum.flat_map(fn root -> [root | Path.wildcard(root <> "/**/*")] end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> hash_file_list()
  end

  @doc false
  def changed_beams(baseline, current) do
    (for {beam, sha} <- current, Map.get(baseline, beam) != sha, do: beam) |> Enum.sort()
  end

  @doc false
  def beam_module(beam) do
    beam |> Path.basename(".beam") |> String.to_atom()
  end

  @doc false
  def ensure_cover!(directory) do
    Mix.ensure_application!(:tools)

    case :cover.start() do
      {:ok, _pid} -> :ok
      {:error, _reason} -> :ok
    end

    beams = directory |> list_beams!() |> Enum.map(&String.to_charlist(Path.join(directory, &1)))
    beams |> :cover.compile_beam() |> List.wrap() |> enforce_beam_results!()
  end

  @doc false
  def import_export!(path) do
    case :cover.import(String.to_charlist(path)) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("cannot import coverage export #{path}: #{inspect(reason)}")
    end
  end

  @doc false
  def module_line_totals(module) do
    Mix.ensure_application!(:tools)

    case :cover.analyse(module, :coverage, :line) do
      {:ok, entries} -> sum_lines(entries)
      {:error, reason} -> Mix.raise("cannot analyse coverage for #{inspect(module)}: #{inspect(reason)}")
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
    |> Enum.map(fn module -> :cover.async_analyse_to_file(module, html_path(output, module), [:html]) end)
    |> Enum.each(&await_cover/1)

    :ok
  end

  defp gate_changed!(settings, changed, current, gate) do
    ensure_cover!(settings.compile_path)
    import_export!(settings.export_path)
    results = Enum.map(changed, &cover_result/1)
    enforce_full_coverage!(results)
    write_module_html!(Enum.map(results, &elem(&1, 0)), settings.output)
    write_baseline_file!(settings.baseline, %{vsn: @vsn, beams: current, gate: gate})
    Mix.shell().info("Qlover holds for #{length(changed)} changed beam(s).")
    :ok
  end

  defp cover_result(beam) do
    module = beam_module(beam)
    {module, module_line_totals(module)}
  end

  defp current_baseline(settings) do
    %{vsn: @vsn, beams: beam_hashes(settings.compile_path), gate: gate_hash(settings.gate_paths)}
  end

  defp decode_baseline!(path, contents) do
    case decode_term(contents) do
      %{vsn: @vsn, beams: beams, gate: gate} when is_map(beams) and is_binary(gate) ->
        %{beams: beams, gate: gate}

      _other ->
        Mix.raise("qlover baseline #{path} is invalid; run full coverage")
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

  defp hash_file!(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end

  defp hash_file_list(files) do
    payload = Enum.map(files, fn file -> {file, hash_file!(file)} end)
    :crypto.hash(:sha256, :erlang.term_to_binary(payload)) |> Base.encode16(case: :lower)
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
    Enum.map_join(failures, "\n", fn {module, {covered, total}} -> "  #{inspect(module)}: #{covered}/#{total} lines" end)
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
```
