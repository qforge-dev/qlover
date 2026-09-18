#!/usr/bin/env bash
# Compares full-suite runs against qlover incrementals across concrete scenarios.
#
# Usage:
#   ./compare.sh
#
# For each scenario the script applies one small change, runs the full suite
# (`mix test --no-stale --cover`, what you would run today for a coverage
# claim) and then `mix test.qlover`, and prints both test counts plus the
# verdict. Each scenario starts from the same green baseline: the whole
# project state (sources, baseline, tracer refs, compiled beams, manifests)
# is snapshotted once as golden and restored afterwards, so scenarios are
# independent and chainable in any order.
#
# Exit status is 0 when every scenario's verdicts agree (both pass or both
# fail) and 1 otherwise -- a mismatch would mean the incremental gate
# disagrees with the full suite.
set -u
cd "$(dirname "$0")"
export MIX_ENV=test

SEED_ARGS="--seed 0"
LOGS="tmp/compare-logs"
mkdir -p "$LOGS"
rm -f "$LOGS"/*.log

MISMATCHES=0
GOLDEN="/tmp/demo-qlover-golden"
rm -rf "$GOLDEN"

snap_golden() {
  rm -rf "$GOLDEN"
  mkdir -p "$GOLDEN"
  # Everything that influences the next run: sources, baseline, tracer
  # refs, compiled beams, and both Mix manifests. tmp/ (logs) is
  # deliberately excluded so restoring never deletes scenario logs.
  cp -a lib test cover _build "$GOLDEN"/
}

restore_golden() {
  rm -rf lib test cover _build
  cp -a "$GOLDEN"/lib "$GOLDEN"/test "$GOLDEN"/cover "$GOLDEN"/_build .
}

count_tests() {
  # Sums every "Result: N passed" / "Result: N/M passed" line in a log.
  # A qlover run may contain two (stale + expansion); "No stale tests"
  # prints no Result line and counts as 0.
  grep -E 'Result: [0-9]+(/[0-9]+)? passed' "$1" 2>/dev/null \
    | sed -E 's/.*Result: ([0-9]+)(\/([0-9]+))? passed.*/\1 \3/' \
    | awk '{if ($2 != "") s += $2; else s += $1} END {print s + 0}'
}

verdict() {
  if [ "$1" -eq 0 ]; then printf 'pass'; else printf 'FAIL'; fi
}

run_full() {
  # shellcheck disable=SC2086
  mix test --no-stale --cover $SEED_ARGS >"$1" 2>&1
  FULL_CODE=$?
  FULL_TESTS=$(count_tests "$1")
}

run_qlover() {
  # shellcheck disable=SC2086
  mix test.qlover $SEED_ARGS >"$1" 2>&1
  QLOVER_CODE=$?
  QLOVER_TESTS=$(count_tests "$1")
}

run_scenario() {
  # $1 = id, $2 = description
  # Mix's own compiler detects recompilation by mtime at 1-second
  # granularity: without this sleep a fast script edits files within the
  # same second as the last compile, Mix skips the rebuild, and qlover
  # hashes stale beams. Humans never hit this; scripts always must.
  sleep 2
  "setup_$1"
  # qlover first: this is the order a real user runs. The full suite goes
  # second because even a no-op `mix test` compile can rewrite manifests
  # and beams, which would pollute the incremental measurement.
  run_qlover "$LOGS/qlover-$1.log"
  run_full "$LOGS/full-$1.log"
  row "$1" "$2"
  restore_golden
}

row() {
  # $1 = scenario id, $2 = human description
  local saved=$((QLOVER_TESTS - FULL_TESTS))
  local full_v qlover_v mark
  full_v=$(verdict "$FULL_CODE")
  qlover_v=$(verdict "$QLOVER_CODE")
  mark=""
  if [ "$FULL_CODE" -eq 0 ] && [ "$QLOVER_CODE" -ne 0 ]; then
    mark="  <-- MISMATCH"
    MISMATCHES=$((MISMATCHES + 1))
  fi
  if [ "$FULL_CODE" -ne 0 ] && [ "$QLOVER_CODE" -eq 0 ]; then
    mark="  <-- MISMATCH (qlover passed where full failed)"
    MISMATCHES=$((MISMATCHES + 1))
  fi
  printf '| %-14s | %-44s | %4s %-4s | %4s %-4s | %+5d |%s\n' \
    "$1" "$2" "$FULL_TESTS" "$full_v" "$QLOVER_TESTS" "$qlover_v" "$saved" "$mark"
}

setup_no_change() { :; }

setup_edit_module() {
  python3 -c "
s = open('lib/demo/pricing.ex').read()
old = 'amount - amount * pct / 100'
new = 'amount * (100 - pct) / 100'
assert old in s, 'pricing body drifted (tree not clean?)'
assert new not in s, 'pricing edit already applied (tree not clean?)'
open('lib/demo/pricing.ex', 'w').write(s.replace(old, new))
"
}

setup_edit_test() {
  if grep -q 'pricing edge cases are covered above' test/pricing_test.exs; then
    printf 'setup_edit_test: marker already present (tree not clean?)' >&2
    exit 1
  fi
  printf '\n# pricing edge cases are covered above\n' >>test/pricing_test.exs
}

setup_add_covered() {
  cat >lib/demo/coupon.ex <<'EOF'
defmodule Demo.Coupon do
  @moduledoc "Coupons: fixed amount off, never below zero."

  @spec apply(number(), number()) :: number()
  def apply(amount, off) do
    if amount - off < 0 do
      0
    else
      amount - off
    end
  end

  @spec label(number()) :: String.t()
  def label(off) do
    "$#{off} off"
  end
end
EOF
  cat >test/coupon_test.exs <<'EOF'
defmodule Demo.CouponTest do
  use ExUnit.Case, async: true

  alias Demo.Coupon

  test "apply subtracts the amount" do
    assert Coupon.apply(100, 15) == 85
  end

  test "apply floors at zero" do
    assert Coupon.apply(10, 15) == 0
  end

  test "apply of the full amount is zero" do
    assert Coupon.apply(15, 15) == 0
  end

  test "label formats the amount" do
    assert Coupon.label(15) == "$15 off"
  end

  test "label works for zero" do
    assert Coupon.label(0) == "$0 off"
  end
end
EOF
}

setup_add_uncovered() {
  cat >lib/demo/dead.ex <<'EOF'
defmodule Demo.Dead do
  @moduledoc "Deliberately uncovered code: nothing references it."

  @spec ping() :: :pong
  def ping, do: :pong

  @spec double(number()) :: number()
  def double(n), do: n * 2
end
EOF
  cat >test/dead_test.exs <<'EOF'
defmodule Demo.DeadTest do
  use ExUnit.Case, async: true

  test "placeholder passes without touching Dead" do
    assert 1 + 1 == 2
  end
end
EOF
}

setup_delete_case() {
  python3 -c "
s = open('test/cart_test.exs').read()
old = '''  test \"has? is false on empty carts\" do
    refute Cart.has?(Cart.new(), \"apple\")
  end
'''
assert old in s, 'cart test drifted (tree not clean?)'
open('test/cart_test.exs', 'w').write(s.replace(old, ''))
"
}

setup_delete_file() {
  rm test/email_test.exs
}

setup_delete_module() {
  rm lib/demo/shipping.ex test/shipping_test.exs
}

setup_tdd_red() {
  cat >test/task_test.exs <<'EOF'
defmodule Demo.TaskTest do
  use ExUnit.Case, async: true

  alias Demo.Task

  test "new tasks start open" do
    assert Task.status(Task.new("write docs")) == :open
  end

  test "closing a task closes it" do
    assert Task.new("x") |> Task.close() |> Task.status() == :closed
  end

  test "titles are kept" do
    assert Task.title(Task.new("write docs")) == "write docs"
  end
end
EOF
}

setup_tdd_green() {
  setup_tdd_red
  cat >lib/demo/task.ex <<'EOF'
defmodule Demo.Task do
  @moduledoc "Tiny task tracker."

  defstruct [:title, :closed?]

  @spec new(String.t()) :: t()
  def new(title), do: %__MODULE__{title: title, closed?: false}

  @spec close(t()) :: t()
  def close(task), do: %{task | closed?: true}

  @spec status(t()) :: :open | :closed
  def status(%__MODULE__{closed?: true}), do: :closed
  def status(%__MODULE__{closed?: false}), do: :open

  @spec title(t()) :: String.t()
  def title(%__MODULE__{title: title}), do: title

  @type t :: %__MODULE__{title: String.t(), closed?: boolean()}
end
EOF
}

printf 'Establishing green baseline (full suite + snapshot)...\n'
rm -rf cover _build
# shellcheck disable=SC2086
mix test.qlover $SEED_ARGS >"$LOGS/baseline.log" 2>&1
if [ $? -ne 0 ]; then
  printf 'Baseline run failed, see %s\n' "$LOGS/baseline.log"
  exit 1
fi
printf 'Baseline green: %s tests.\n\n' "$(count_tests "$LOGS/baseline.log")"

printf '| %-14s | %-44s | %-10s | %-10s | %-5s |\n' "scenario" "change" "full" "qlover" "saved"
printf '|-%-14s-|-%-44s-|-%-10s-|-%-10s-|-%-5s-|\n' \
  "--------------" "--------------------------------------------" \
  "----------" "----------" "-----"

# The steady state (sources, baseline, refs, beams, manifests) is
# snapshotted once as golden; every scenario restores it, so scenarios are
# independent and order-free. No warmup run is needed: file selection comes
# from qlover's content-keyed reference graph, not from ExUnit's stale
# manifest, so the first incremental after the baseline is already
# selective.
sleep 2
run_full "$LOGS/full-warmup.log"
run_qlover "$LOGS/qlover-warmup.log"
row "cold" "first incremental after baseline"
snap_golden

run_scenario no_change "nothing changed"
run_scenario edit_module "refactor Demo.Pricing (covered)"
run_scenario edit_test "comment-only edit to pricing_test.exs"
run_scenario add_covered "new Demo.Coupon + 5 covering tests"
run_scenario add_uncovered "new Demo.Dead, test covers nothing (red)"
run_scenario delete_case "drop 1 redundant test from cart_test.exs"
run_scenario delete_file "delete email_test.exs (sole coverer, red)"
run_scenario delete_module "delete Demo.Shipping + its tests"
run_scenario tdd_red "new task tests, no implementation (red)"
run_scenario tdd_green "new task tests + implementation"

printf '\nFull logs in %s (full-<id>.log vs qlover-<id>.log).\n' "$LOGS"
if [ "$MISMATCHES" -ne 0 ]; then
  printf '%d scenario(s) where verdicts disagree!\n' "$MISMATCHES"
  exit 1
fi
printf 'All verdicts agree: qlover ran a fraction of the suite with identical outcomes.\n'
