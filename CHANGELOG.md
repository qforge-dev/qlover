# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `mix test.qlover --no-stale` to force a full test-suite rerun and refresh the
  coverage baseline.

## [0.1.2] - 2026-09-18

### Fixed

- Treat `test_helper.exs` as a suite-wide input: no missing-attribution
  warning, and helper additions, edits, or deletions always require a full
  run, including when tracer records exist.
- Round coverage percentages down to two decimals in `mix test.qlover`,
  so coverage below 100% displays as `99.99%` rather than `100.00%`.
  Threshold checks still use exact counts.

## [0.1.1] - 2026-09-18

### Added

- `./release` to bump the version (patch by default), update the changelog,
  commit and push the release tag, and publish the GitHub release that
  triggers Hex package and documentation publishing.
- Per-invocation test counts: `qlover: ran X tests; didn't run Y tests.`,
  including failed and unchanged runs, with ExUnit skips/exclusions listed
  separately. Per-file counts follow edits and deletions and are shared
  with cached baselines.
- Automatic releases: pull-request quality checks, rolling `dev` GitHub
  packages on successful pushes to `main`, and Hex package/docs publishing
  for non-prerelease GitHub releases whose tags match `VERSION`.
- Per-test-file attribution: test-only edits gate incrementally via a
  compiler-tracer reference graph (`Qlover.Tracer`, enabled with
  `elixirc_options` + `test_elixirc_options`) with transitive lib closure,
  focused expansion runs, and fresh-export union. Non-code fixture changes
  and tests without reference data still fall back to the full suite,
  fail-closed.
- Baseline format v4 (non-test gate inputs, per-test-file hashes,
  reference snapshot, lib edge graph). Older baselines are treated as
  invalid and trigger one full re-baseline.
- Beam hashing ignores path-volatile chunks (`Dbgi`, `Docs`, `CInf`,
  `ExCk`, `Line`): identical sources hash equally in any checkout and
  pure line shifts need no fresh proof. Unreadable beams fall back to raw
  content hashes.
- `MIX_ENV=test` guard on both tasks (same rule as `mix test` itself),
  with `preferred_envs` setup documented for host projects.
- Second scratch export (`--expansion-export`) for the focused expansion
  run; both exports are unioned (same code version) and cleaned up. The
  expansion run passes `--no-stale` so host `test` aliases that inject
  `--stale` cannot silently empty its explicit file list, and compiled
  support files are excluded from it (requiring them would reload plain
  code over instrumented code and zero their coverage).
- `examples/demo`: runnable 48-test shop plus `compare.sh` measuring
  full-suite vs incremental across 11 scenarios (table in `README.md`);
  exits non-zero on any verdict mismatch. Now also carries a hostile
  `test: ["test --stale"]` alias mirroring the labqoat convention, proving
  qlover's explicit `--no-stale`-first argv cannot be shrunk by it.
- Shared content-addressed cache (`QLOVER_CACHE_DIR`, default
  `~/.cache/qlover`): snapshots write through under content keys, missing
  baselines fetch and heal locally, tracer records merge across
  directories. Verified with a cross-directory gating test.

## [0.1.0] - 2026-09-17

### Added

- `mix qlover` gate task with three modes: `--eligible`, `--write-baseline`,
  and default gating of changed beams on fresh line coverage alone.
- `mix test.qlover` single-command runner: stale + gate when eligible,
  full + snapshot otherwise, with test-arg passthrough, managed-flag
  rejection, and fail-closed subprocess exit codes. `cover.sh` delegates
  to it.
- Hermetic test suite (33 tests) covering baseline roundtrip, eligibility,
  gate-input drift, changed-beam pass/reject, missing export, deleted-beam
  pruning, single-command orchestration, and fail-closed error paths.
- Hex packaging metadata, Apache-2.0 license, and documentation.
