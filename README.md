# Qlover

Incremental line-coverage gating for ExUnit runs. Qlover lets a focused
subset of tests satisfy a 100% coverage gate without rerunning the whole
suite, by combining fresh coverage for everything that could have changed
with a trusted baseline from the last green full run.

Status: core gate task (`mix qlover`), single-command runner
(`mix test.qlover`), per-test-file attribution, `cover.sh` wrapper, and Hex
packaging are implemented and tested (109 tests, 100% line coverage). See
`PLAN.md` for goals, architecture, and roadmap.

## Background: how Erlang `:cover` works

Elixir's coverage is Erlang's `:cover` (`lib/tools/src/cover.erl` in OTP).
It counts how many times each *executable line* runs. There is no sampling
and no tracing involved — it is instrumentation plus counters.

**Actors.** `cover:start/0` spawns a `cover_server` process owning ETS
tables: a bump→counter-index mapping table, a table holding instrumented
binaries for late-joining nodes, and a collection table for results. In a
distributed setup one main node coordinates remote `cover_server`s.

**Cover-compiling.** Before measurement, each module is *cover-compiled*:
`:cover` reads the module's abstract code (`debug_info` chunk) with
`beam_lib`, rewrites it with `sys_coverage:cover_transform/2`, recompiles
with `compile:forms/2`, and hot-loads the binary via
`code:load_binary/3`. No source or `.beam` file changes;
`code:which(Mod)` returns `cover_compiled`.

**Instrumentation.** `sys_coverage` (`lib/compiler/src/sys_coverage.erl`)
walks the abstract format and inserts an `{executable_line, Line, Index}`
marker before each executable expression in clause bodies, `case`,
`receive`, `try`, `fun`, and comprehension bodies. Heads, guards, patterns,
comments, and blank lines get no marker. `andalso`/`orelse` are expanded to
`case` so both branches are tracked. Each distinct
`{module, function, arity, clause, line}` tuple (the `#bump{}` record) maps
to one counter index.

**Counting.** Two backends:

- *Legacy*: markers become
  `counters:add(persistent_term:get({cover, Mod}), Index, 1)` calls. Each
  module owns a `counters` array (`write_concurrency`), referenced from a
  persistent term.
- *Native (OTP 27+)*: when `code:coverage_support()` is true, the compiler
  flag `force_line_counters` makes the VM maintain `cover_id_line` counters
  itself — no injected calls. Reads go through
  `code:get_coverage/2`, resets through `code:reset_coverage/1`.

**Analysis.** `:cover.analyse(Mod, Analysis, Level)` drains the counters
(zeroing them) into the collection table keyed by `#bump{}` and aggregates:
`Analysis` is `coverage` (`{covered, not_covered}`) or `calls` (hit counts);
`Level` is `module | function | clause | line`. `analyse_to_file` annotates
a source copy with per-line hit counts.

**Export/import.** `:cover.export/2` dumps `{file, Module, File}` headers
plus `{#bump{}, Count}` pairs to a `.coverdata` file;
`:cover.import/1` adds them into the collection table. Merging is additive,
which is correct for combining *disjoint* runs (partitions) but silently
wrong across source changes: old line numbers survive as phantom entries,
so yellowing imports must never mix code versions for the same module.

## How Elixir uses it

`mix test --cover` delegates to `Mix.Tasks.Test.Coverage.start/2`, which
calls `:cover.local_only/0`, cover-compiles every beam in the compile path,
runs the suite, then prints a per-module line-coverage table with a
configurable summary threshold (`test_coverage: [summary: [threshold: 100]]`).
Line 0 (compiler-generated code) is skipped, and a line counts as covered
if *any* of its entries was hit.

`--export-coverage NAME` (or `--partitions N`) skips the report and writes
`cover/NAME.coverdata` instead; `mix test.coverage` cover-compiles, imports
every `cover/*.coverdata`, and reports the union. This is the sanctioned
"collect coverage over different runs" mechanism — and the one Qlover builds
on. It works for Elixir unchanged because instrumentation happens at the
Erlang abstract-code/BEAM level: Elixir modules carry the same `debug_info`
with `.ex` line numbers.

## The problem

`mix test --cover` measures only the tests that ran. With `--stale`, a
one-module change runs a handful of test files, so the report shows ~50%
for a fully covered codebase: the untouched half simply did not execute.
Naively merging the stale subset with the previous full export "fixes" the
number but also masks real regressions forever, because the old export
already claimed 100%.

What we want: *"this test run owns this coverage."* If the tests covering a
module did not need to rerun, their coverage claim still stands; if they
did rerun, the fresh numbers replace it. Qlover selects exactly the tests
that could cover changed code from its own content-keyed reference graph,
so a focused run plus the baseline is equivalent to a full run.

## Design

Qlover partitions the gate instead of merging line counts:

- A **baseline** file (`cover/.qlover_baseline`, Erlang term) records
  a stable hash of every compiled beam (all chunks except `Dbgi`, `Docs`,
  `CInf`, `ExCk`, and `Line`, which embed absolute paths, option snapshots,
  or nondeterministic metadata — so identical sources hash equally in any
  checkout, and pure line shifts need no fresh proof), a combined hash of
  the non-test gate inputs (`priv/repo/`, `config/`, `mix.exs`, `mix.lock`),
  and per-test-file content hashes plus the traced module reference graph.
- After a green full run, `mix qlover --write-baseline` snapshots both.
- On a later change, `mix qlover --eligible` passes only if the baseline
  exists and every gate input is byte-identical. Non-test input changes
  (config, migrations, dependencies) fall back to the full suite. Test
  edits gate incrementally through per-test attribution instead: only the
  modules a changed test could have covered must be re-proven fresh.
- The focused run executes with `--no-stale --cover --export-coverage`
  over exactly the affected test files (changed files plus every runnable
  file referencing an affected module), then `mix qlover` recomputes beam
  hashes. Beams identical to baseline are trusted; each new-or-changed
  beam must show 100% line coverage in the fresh export alone (complete,
  because all its referencing tests reran). Changed modules get fresh
  HTML reports; the baseline is then updated, so incrementals chain.
- No beam changes at all passes without needing any export (when nothing
  is affected, no test process even starts).

Parity details that matter: line-level analysis only (module-level counts
raw bumps and disagrees with the Mix summary), line 0 skipped, covered-wins
per line — exactly the `Mix.Tasks.Test.Coverage` semantics, so incremental
and full gates agree. Per-module cover-compile failures raise instead of
being silently skipped (upstream ignores them, which would be a false pass
here). No `:cover.stop/0` is ever called, so the task is safe to exercise
inside a test suite, including one already running under cover.

## Installation

Add as a test-only dependency:

```elixir
defp deps do
  [
    {:qlover, "~> 0.1", only: :test, runtime: false}
  ]
end
```

Then enforce the 100% summary threshold so both full and focused runs
gate on the same number, and pin the tasks to the test environment
(otherwise they would build and gate the `dev` tree instead):

```elixir
def project do
  [
    ...,
    test_coverage: [summary: [threshold: 100]]
  ]
end

def cli do
  [preferred_envs: [qlover: :test, "test.qlover": :test]]
end
```

Both tasks refuse to run outside `MIX_ENV=test` with a message saying so
(same rule as `mix test` itself).

## Usage

Run one command instead of `mix test --cover`:

```sh
mix test.qlover
```

It picks the path itself and says which one: a focused run of exactly
the affected test files plus gating when the baseline matches, otherwise
the full suite plus a fresh baseline (first runs, missing/invalid
baselines, and config/migration/dependency changes all land here). File
selection comes from qlover's own content-keyed reference graph — no
stale manifest is involved — so it is deterministic across worktrees and
machines, and the first incremental after a baseline is already
selective. Plain `mix test` is untouched, so `mix test test/foo_test.exs`
and ad-hoc flags keep working. Extra arguments are appended to the
selection (`mix test.qlover --seed 0`); extra *file* arguments widen it,
which stays sound because all coverage comes from one code version. The
flags `--stale`, `--no-stale`, `--cover`, `--no-cover`,
`--export-coverage`, `--failed`, `--partitions`, `--dry-run`, and
`--no-compile` are managed by the task and rejected when passed
explicitly.

Want the flag spelling instead? Mix does not let dependencies add flags to
`mix test`, but one alias in your own `mix.exs` gets you there:

```elixir
def project do
  [
    ...,
    aliases: aliases()
  ]
end

defp aliases do
  [
    test: fn args ->
      if "--qlover" in args do
        Mix.Task.run("test.qlover", args -- ["--qlover"])
      else
        Mix.Tasks.Test.run(args)
      end
    end
  ]
end
```

With that, `mix test --qlover` gates while bare `mix test` stays vanilla.

## Example: concrete numbers

`examples/demo/` is a runnable 48-test shop (6 modules, 100% gate) with a
script that measures both approaches side by side:

```sh
cd examples/demo
./compare.sh
```

Each scenario applies one change, runs the full suite and then
`mix test.qlover`, and prints test counts plus verdicts. The script exits
1 if any verdicts disagree:

| scenario      | change                                    | full    | qlover  | saved |
|---------------|-------------------------------------------|---------|---------|-------|
| cold          | first incremental after baseline          | 48 pass | 0 pass  | -48   |
| no_change     | nothing changed                           | 48 pass | 0 pass  | -48   |
| edit_module   | refactor Demo.Pricing (covered)           | 48 pass | 8 pass  | -40   |
| edit_test     | comment-only edit to pricing_test.exs     | 48 pass | 8 pass  | -40   |
| add_covered   | new Demo.Coupon + 5 covering tests        | 53 pass | 5 pass  | -48   |
| add_uncovered | new Demo.Dead, test covers nothing (red)  | 49 FAIL | 1 FAIL  | -48   |
| delete_case   | drop 1 redundant test from cart_test.exs  | 47 pass | 15 pass | -32   |
| delete_file   | delete email_test.exs (sole coverer, red) | 40 FAIL | 0 FAIL  | -40   |
| delete_module | delete Demo.Shipping + its tests          | 40 pass | 0 pass  | -40   |
| tdd_red       | new task tests, no implementation (red)   | 51 FAIL | 3 FAIL  | -48   |
| tdd_green     | new task tests + implementation           | 51 pass | 3 pass  | -48   |

Why each row lands there:

- **cold**: no warmup run exists anymore — selection comes from the
  content-keyed reference graph, not from ExUnit's stale manifest, so the
  first incremental after the baseline is already selective.
- **no_change**: hashes match, gate passes with zero tests.
- **edit_module**: one run of `pricing_test` (8); the gate proves the
  `Pricing` beam fresh. (`Receipt` depends on `Pricing` but its code is
  unchanged, so it needs no re-run.)
- **edit_test**: one run of the changed file (8), which re-proves
  `Pricing`.
- **add_covered**: one run of the 5 new tests; the new beam is proven and
  the snapshot extends.
- **add_uncovered**: 1 execution, gate names `Demo.Dead`; the full suite
  fails identically on 49.
- **delete_case**: `cart_test` shrinks to 7; the run covers it plus
  `receipt_test` (8), which shares `Cart` coverage.
- **delete_file**: 0 tests run, gate names the now-uncovered `Demo.Email`;
  the full suite fails the same way on 40.
- **delete_module**: the vanished beam is pruned from the baseline, 0
  tests, pass.
- **tdd_red**: the 3 new tests fail; the run aborts before gating and the
  baseline is untouched.
- **tdd_green**: one run of the 3 tests, the new beam is proven, snapshot
  extends.

The pattern: green incrementals run a handful of tests, red ones fail
with a handful too — and every verdict matches the full suite.

The manual three-step flow is still available for CI escape hatches (it
uses `mix test --stale` the classic way, so it still needs a warmed stale
manifest where `mix test.qlover` needs none):

```sh
mix qlover --eligible || { mix test --no-stale --cover && mix qlover --write-baseline; }
mix test --stale --cover --export-coverage .qlover_fresh
mix qlover
```

The scratch export (`cover/.qlover_fresh.coverdata`; the gate also
accepts a second one at `cover/.qlover_expansion.coverdata`) is
import-only input for the gate and is always deleted afterwards — by the
task on success and before each run — so a later `mix test.coverage`
never unions a stale partial into a full report.

`mix qlover` exits nonzero listing every changed module below 100%, and
updates the baseline plus per-module HTML only on success. Test failures in
the stale step abort before gating, so a red suite can never mint a green
baseline. Non-test changes under `priv/repo/`, `config/`, `mix.exs`, or
`mix.lock` fall back to the full suite instead of guessing. Deleting a
module prunes it from the baseline without needing an export.

## Test attribution

Only *decreases* in coverage need fresh proof, and only changed tests can
decrease anything: a changed test's old references (pinned in the baseline
snapshot) conservatively bound what it could have covered, closed
transitively over lib-to-lib references. New test files only add coverage,
so they need no proof — but they still run, so a red new test aborts
before gating.

Concretely, the gate computes the affected modules (changed tests' old
references, closed over the lib graph, plus fresh downstream edges of
changed beams) and requires each of them at 100% in fresh data alone.
`mix test.qlover` runs exactly the affected test files — changed files
plus every runnable file referencing an affected module — in a single
`mix test --no-stale` invocation and gates its export. No stale manifest
is involved, so selection is deterministic and shareable; anything
unattributable (non-code fixture changes, tests with no reference data)
falls back to the full suite instead of guessing. User-supplied file
arguments widen the selection, which stays sound because all coverage
still comes from one code version.

Reference data comes from the compiler tracer (`Qlover.Tracer`), enabled
with two lines in the host project:

```elixir
def project do
  [...,
   elixirc_options: [tracers: [Qlover.Tracer]],
   test_elixirc_options: [tracers: [Qlover.Tracer]]]
end
```

(`elixirc_options` covers `mix compile`; test files are required
separately by `mix test`, so they need `test_elixirc_options`.) Without
tracer data every test edit falls back to the full suite, exactly like
before — attribution is purely additive and can never pass where the old
gate would fail.

Known residuals, all fail-closed in the common case and documented as
trust assumptions: dynamically dispatched calls (`apply/3` with a variable
module and friends) are invisible to the tracer, protocol implementations
are covered without naming their modules, and externals outside `test/`
that are not gate inputs are untracked.

Paths can be overridden when invoking the tasks directly:

```sh
mix test.qlover --baseline cover/.qlover_baseline --export cover/.qlover_fresh.coverdata --expansion-export cover/.qlover_expansion.coverdata
mix qlover --baseline cover/.qlover_baseline --export cover/.qlover_fresh.coverdata --expansion-export cover/.qlover_expansion.coverdata
```

## Sharing work across checkouts

Snapshots and tracer records are content-keyed, so parallel worktrees
(and CI agents) share them instead of each paying for a full baseline
run. Set the same `QLOVER_CACHE_DIR` everywhere (it defaults to
`~/.cache/qlover`, XDG-aware; `""` disables it):

```sh
export QLOVER_CACHE_DIR=~/.cache/qlover
mix test.qlover   # worktree A: full run once, baseline cached
cd ../worktree-b  # identical content
mix test.qlover   # compile, fetch baseline, gate passes with 0 tests
```

A cache hit is re-verified against the local tree exactly like a local
baseline, so it can never pass where a local baseline would fail — the
only new trust is "a green full run happened for this content", the same
trust the baseline file already carries. Corrupt blobs are ignored, cache
write failures degrade silently, and last-writer-wins record races only
ever cost a fallback, never a pass. Two caveats: compiled beams embed
absolute paths, so each checkout still compiles locally (cheap next to
test runs), and a worktree that *changes* code still needs its own test
execution — the cache removes the duplicate full runs, not the proving
ones. The same layout works over remote storage; writers must be trusted
(CI), readers verify locally.

## Prior art

- OTP `:cover` partitions (`--partitions`, `--export-coverage`,
  `mix test.coverage`): union of disjoint runs, no invalidation.
- `mix-stale-coverage` (sibling experiment): compiler tracers build a
  test-file→module reference graph for per-test-file attribution. Qlover's
  phase 4 adopts the same reference-graph idea but attributes whole runs
  instead of isolating per-file runs: one explicit `mix test --no-stale`
  invocation over exactly the affected files (same code version, so no
  async interference to beat). Qlover's coarser beam-level partition
  remains as the no-tracer fallback: without reference data, test edits
  fall back to full.
