# Runtime-attributed coverage: regression tests and implementation plan

## Goal

After a passing baseline, editing one test file should rerun that file and
replace its coverage contribution. Other files' valid coverage of unchanged
application code remains reusable, even when all files require and execute the
same module. Removing a line's last owner must fail the coverage gate.

This change starts with file-level ownership. The baseline must answer both
"which lines did this file execute?" and "which files covered this line?".

## Executable acceptance tests

`test/trace_coverage_test.exs` exercises the existing `mix test.qlover` command in
temporary Mix projects, using this checkout as a path dependency. It does not
mock the runner, fabricate a baseline, depend on a proposed manifest layout, or
call APIs that have not been implemented.

Each project has two async test files requiring `TraceFixture.Shared`:

- Both initially execute `common/0`.
- A executes the `:left` branch of `branch/1`.
- B executes the `:right` branch of that same function.
- Some scenarios also give B ownership of `:left`.

Every test establishes an actual passing 100% baseline before changing an input.
Execution markers outside the tracked test and gate paths identify which test
bodies ran, including duplicate executions. Assertions also check exit status,
coverage failure diagnostics, baseline preservation, and relevant CLI counts.
Each fixture has a private cache and forces its initial full run with
`--no-stale`, so evidence from another test cannot satisfy baseline setup.

| Test scenario | Required behavior | Implementation needed |
| --- | --- | --- |
| Editing one file | Run A once; combine its fresh hits with B's stored hits; the next invocation runs nothing | Runtime collection, persistence, row replacement, focused planning |
| Dry selection | Select only A; execute nothing; preserve baseline bytes | Evidence-aware planning shared by dry and real runs |
| Removing a sole owner's branch | Run A only; fail because `:left` is uncovered; preserve baseline | Executable-line inventory and removal of superseded hits |
| Removing a shared line's hit | Run A only; pass using B's existing `common/0` hit | Independent ownership of overlapping lines |
| Deleting a redundant owner | Delete A while B covers both branches; pass with zero tests | Remove a row and gate directly from surviving evidence |
| Deleting a sole owner | Delete A while B covers only `:right`; fail with zero tests | Detect missing owners without requiring a fresh export |
| Successive edits | First remove B's `:left` hit successfully; then removing A's hit must fail | Replace rows across successful baselines rather than accumulating history |
| Overlapping async tasks | Attribute task hits to their parent files; reuse B and detect loss of A's branch | Race-safe context and spawn ownership |
| Changed application code | Adding an unexecuted function fails despite the old passing baseline | Version-bound evidence and complete executable-line inventory |

The task scenario uses a two-party barrier inside the spawned tasks during the
baseline run. Both tasks must enter before either can leave; no sleeps or lucky
scheduling are needed. Later focused runs disable only that barrier through the
fixture's environment, without editing suite helpers or application code.

Run the acceptance file with:

```sh
mix test test/trace_coverage_test.exs --warnings-as-errors --seed 0
```

The new tests carry the `:trace_coverage` tag and are enabled in normal test runs.
All nine scenarios now pass on the supported OTP 29 / Elixir 1.20.2 target.

Before implementation: **8 failures, 1 passing control**. Every baseline setup
passed, but excess file execution (or selection in `--dry`) prevented precision.
After implementation: **9 passing**. The command above and `scripts/check` pass.

To check the pre-existing suite independently:

```sh
mix test --exclude trace_coverage --warnings-as-errors
```

## Why the current code cannot satisfy the tests

`Qlover.Tracer` records compile-time file-to-module references. In
`Qlover.Attribution.plan/1`, a modified or deleted file's old references expand
into modules to prove, then every surviving referencer is selected. The two
fixture files therefore widen each other's runs.

`Mix.Tasks.Qlover.gate_proven!/5` reads aggregate `:cover` exports and requires
fresh full coverage for those modules. Narrowing just the selection would make
the success scenarios fail: A's fresh execution cannot cover B's distinct branch.
Skipping the gate would incorrectly pass the coverage-loss scenarios.

The replacement uses runtime ownership and an evidence-merging gate. Compiler
references alone cannot distinguish the two deletion scenarios.

## Implementation sequence

### 1. Introduce an attributed coverage backend

- Make `Qlover.Coverage` implement Mix's custom coverage-tool `start/2` contract.
  Install it in the existing child-VM runner in
  `lib/mix/tasks/test.qlover.ex`, before Mix starts the host application.
- Add `Qlover.Coverage.Instrumenter` to read each target BEAM's abstract code,
  enumerate executable coverage points, replace those points with runtime hit
  probes, and compile/load the instrumented binary in the child VM.
- On the current OTP 29.0.3 target, investigate
  `:sys_coverage.cover_transform/2`, which is the transform used by `:cover`.
  Its executable-line markers provide a concrete instrumentation path. It is
  undocumented: isolate it behind a version-checked adapter and test the supported
  OTP/Elixir matrix rather than assuming it is a stable public API.
- Record the full probe inventory before running tests. Unexecuted functions and
  branches must remain in the denominator. Preserve source locations, duplicate
  line aggregation, generated-line handling, and configured module exclusions.
- Add `Qlover.Coverage.Runtime` with a deduplicated collector, initially ETS-based.
  Exclude the collector from its own instrumentation to avoid recursion. Bound
  all hit records to the original module version and this run's identifier.
- Use a Qlover-specific export. Ordinary `.coverdata` contains no file ownership
  and cannot establish an attributed baseline.

Before using the new backend for decisions, compare its executable-line and hit
sets against native cover on representative language constructs. The current
acceptance fixture alone is not enough to establish instrumentation parity.

### 2. Bind runtime hits to file execution contexts

- Add a small, version-tested ExUnit integration that establishes ownership
  synchronously in the executing process, before user setup or test code.
  Prototype hooks around generated ExUnit setup callbacks and callback
  registration; verify their ordering against the supported ExUnit versions.
- Track test bodies, `setup`, `setup_all`, `on_exit`, and test-file loading.
  Retain phase and test identity internally, then aggregate to the owning file.
  Formatter events are asynchronous and cannot establish ownership in time for
  the first probe.
- Use a dedicated BEAM trace session for spawn ancestry. A child can hit a probe
  before its spawn event reaches the collector: retain PID-scoped evidence and
  reconcile ancestry after draining traces. Do not assume process dictionaries
  are inherited. Segment reused processes when execution contexts change.
- Account for teardown and descendant completion before sealing the report.
  Collector failure, incomplete instrumentation, and interrupted execution must
  prevent a reusable baseline from being committed.
- Give application startup and suite helpers explicit suite-level scopes.
  Treat unresolved worker hits as unknown, not as reusable suite coverage.
- Shared, long-lived servers require request-scoped context. Add adapters/context
  propagation where supported; obtain evidence through isolated-file runs or
  conservative refreshes where attribution remains ambiguous. A server PID or
  global "current test" variable does not establish causality.

Deliverable: a completed full run yields separate A and B hit sets, including
their shared line, distinct branches, and child-task hits.

### 3. Persist versioned evidence

Introduce a manifest with:

- File hashes and per-file hit sets, including an explicit complete-but-empty row.
- Module execution hashes and executable probe inventories.
- A normalized source/probe-map fingerprint.
- Dependency and suite-input fingerprints.
- Collector/backend format, runtime compatibility, and completion metadata.

Derive reverse line-to-file and module-to-file indexes from those records.
Persist only after both tests and the coverage gate succeed, using atomic
replacement for local and shared-cache artifacts.

Update `Mix.Tasks.Qlover` snapshot loading/writing and `Qlover.Attribution` cache
keys. Version-4 baselines need an attributed full refresh; module references
cannot be upgraded into observed line ownership. Normalize paths for worktree
sharing. The current `stable_chunks/1` excludes the BEAM `Line` chunk, so retain a
separate source-map identity to prevent line shifts from mislabeling cached hits.

### 4. Replace contributions and gate the union

For test-only changes to fully attributed, unchanged application code:

1. Remove all old rows for modified, deleted, and rerun files.
2. Run added/modified files and collect complete replacement rows.
3. Preserve independently valid rows for unexecuted files.
4. Union those rows with valid suite-level evidence.
5. Compare the union against the current executable-line inventory.
6. Commit only on success; otherwise preserve the previous baseline.

Replacing B's row must discard its former `:left` hit even if another file still
covers that line. The successive-edits test checks that this removal survives a
successful baseline advancement.

Deletion-only changes need no test process or scratch export when existing
evidence is complete. The union can either prove coverage or identify exactly
which lines lost their last owner. Keep zero-test success/failure counts accurate
and prune deleted files from the successful inventory.

### 5. Make the planner consume evidence

- Add the attributed path to `Qlover.Attribution.plan/1` and `explain_plan/1`.
  Fully attributed test-only changes select added/modified runnable files without
  module-reference expansion.
- Drive execution and `--dry` from the same plan. Include reasons for fresh
  selection, retained evidence, and any conservative fallback.
- Replace aggregate import gating in `Mix.Tasks.Qlover` with the union gate for
  attributed runs. Reuse exact percentage calculations and test-count reporting.
- Preserve conservative behavior for legacy or missing evidence. Existing tests
  that provide only reference snapshots describe that fallback path; do not
  change their expected selections to claim precision without runtime evidence.

At this point the test-edit, deletion, dry-run, and successive-edit regressions
should pass together. A planner-only shortcut cannot satisfy the coverage gate.

### 6. Invalidate changed code and finish integration

- Initially invalidate application changes at module granularity. Old-version
  hits cannot prove the new module's lines, even if line numbers coincide.
- Select prior runtime owners plus relevant compiler/dependency referencers.
  Invalidate affected test rows, including their contributions to other modules,
  and replace them after execution. Retain compiler tracing for macros,
  compile-time effects, and conservative dependencies.
- Handle deleted modules, helpers, fixtures, configuration, and source-map changes
  explicitly. Historical runtime execution cannot predict every new path.
- Finish attributed reports and CLI export handling. Explain lost ownership with
  source locations and prior owners. Keep baseline writes contingent on the
  child process's final success, not just coverage finalization.

## Verification before shipping

The acceptance file and `scripts/check` pass. Additional tests now cover
setup/setup_all/on_exit, native-cover parity on representative constructs,
corrupt reports, filtered runs, source shifts, suite-level evidence, cache reuse
across worktrees, explicit empty rows, and a zero-test executable-line gate for
new unreferenced modules. Broader runtime-matrix testing and
automatic request-scoped attribution for long-lived shared servers remain future
work; their unresolved hits are not reusable evidence.

The repeatable smoke benchmark is `elixir scripts/bench_trace_coverage.exs`.
On OTP 29.0.3 / Elixir 1.20.2 (two trivial async files, warm dependency
compilation), one sample measured native full 613 ms, attributed full 615 ms,
and a one-file edit 626 ms. Instrumentation took 4.7–5.0 ms; collection
1.5–2.9 ms. The collector used 39–121 KB; the trace queue sampled at seal
was empty, with zero unknown hits. Compressed manifests were 868–876 bytes;
the focused edit had zero conservative fallbacks in one attempt. VM startup
dominates this tiny fixture, and queue-at-seal is not peak backlog: benchmark
representative host projects before claiming a latency win.

The success criterion is precise, reusable coverage evidence with a useful
incremental execution cost.
