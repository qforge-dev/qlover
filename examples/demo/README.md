# Demo: less repeated test work

A small shop domain with six business modules, six test files, **48 tests**,
and a 100% line-coverage requirement. Each scenario compares
`mix test.qlover` with a full `mix test --no-stale --cover` run.

## Results

| Scenario | Full suite | qlover | Result, both |
|:---------|-----------:|-------:|:-------------|
| Initial baseline, cache disabled | 48 | 48 | Pass |
| First unchanged rerun after baseline | 48 | 0 | Pass |
| Another unchanged rerun | 48 | 0 | Pass |
| Refactor `Demo.Pricing` | 48 | 8 | Pass |
| Comment-only edit to `pricing_test.exs` | 48 | 8 | Pass |
| Add `Demo.Coupon` and 5 covering tests | 53 | 5 | Pass |
| Add `Demo.Dead` and a test that never calls it | 49 | 1 | Coverage fails |
| Delete one redundant cart test | 47 | 15 | Pass |
| Delete the only test file covering `Demo.Email` | 40 | 0 | Coverage fails |
| Delete `Demo.Shipping` and its tests | 40 | 0 | Pass |
| Add 3 tests before implementing a feature | 51 | 3 | Tests fail |
| Add the implementation for those 3 tests | 51 | 3 | Pass |

The initial baseline requires all 48 tests. The script's `cold` row means
the **first rerun after that baseline**, which is already incremental.
A zero-test failure means qlover cannot establish the required fresh
coverage with the remaining tests; it does not accept the old result.

These counts measure test executions, not elapsed time. The example's
tests are deliberately small, so startup and coverage overhead can dominate
its runtime. Use your own suite to measure wall-clock savings.

## Run it

From a clone of the repository:

```sh
cd examples/demo
QLOVER_CACHE_DIR="" ./compare.sh
```

Disabling the shared cache ensures the initial run actually executes the
full suite. Each scenario starts from the same saved green state. The
script applies a change, runs qlover first and full coverage second, then
restores the source files, baseline, reference records, and build files.
It exits with status 1 if the two verdicts disagree.

The script rewrites the demo files while running; use a clean demo tree.
Logs are saved under `tmp/compare-logs/` for inspection.

## Layout

- `lib/demo/` — cart, pricing, email, inventory, shipping, and receipt.
  Receipt depends on cart and pricing to exercise shared dependencies.
- `test/` — one eight-test file per business module.
- `compare.sh` — creates the additions and deletions for each scenario.
- `mix.exs` — test-only dependency, reference tracing, coverage threshold,
  and test-environment task settings.

## README animation

The [side-by-side animation](../../docs/assets/comparison.gif) illustrates
three rows from this table. It is not a recording or a timing benchmark.
The [asset instructions](../../docs/assets/README.md) explain how to regenerate it.
