# Demo: concrete before/after numbers

A tiny shop domain (6 lib modules, 6 test files, **48 tests**, 100%
coverage gate) with a script that measures full-suite runs against
`mix test.qlover` across everyday changes.

## Run it

```sh
cd examples/demo
./compare.sh
```

Takes ~3 minutes. Each scenario applies one change, runs the full suite
(`mix test --no-stale --cover`, what you would run today for a coverage
claim) and then `mix test.qlover`, and prints both test counts plus the
verdict. Every scenario starts from the same green baseline (sources,
baseline, tracer refs, beams, and manifests are snapshotted once and
restored afterwards), and the script exits 1 if any verdicts disagree.

## Layout

- `lib/demo/` — `cart`, `pricing`, `email`, `inventory`, `shipping`
  (isolated modules) plus `receipt` (depends on `cart` + `pricing`, so
  changes fan out to it — on purpose).
- `test/` — one 8-test file per module.
- `compare.sh` — the scenarios. New files for the add/TDD cases are
  created inline by the script; nothing extra is checked in.

## Wiring

`mix.exs` shows the recommended setup: qlover as a test-only dep, the
tracer on `elixirc_options` + `test_elixirc_options` (scoped to
`Mix.env() == :test`, since the tracer module only exists in `:test`),
`test_coverage: [summary: [threshold: 100]]`, and `preferred_envs` for
both tasks.
