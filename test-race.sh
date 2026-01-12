#!/bin/bash
# test-race.sh - Demonstrates ln -sfn race condition
#
# Run this to see the bug yourself. You should see errors with
# the naive approach, zero errors with atomic-deploy.

set -euo pipefail

echo "=== Race Condition Test ==="
echo ""

# Setup
rm -rf test-race-dir
mkdir -p test-race-dir/releases/v1 test-race-dir/releases/v2
echo "v1" > test-race-dir/releases/v1/version
echo "v2" > test-race-dir/releases/v2/version
cd test-race-dir
ln -s releases/v1 current

echo "Testing naive ln -sfn approach..."
echo ""

# Reader loop - runs in background
(
  for _ in {1..10000}; do
    cat current/version 2>/dev/null || echo "ENOENT"
  done
) > reads.log &

reader_pid=$!

# Writer loop - rapidly swaps symlink using naive approach
for _ in {1..1000}; do
  ln -sfn releases/v1 current
  ln -sfn releases/v2 current
done

wait $reader_pid

errors=$(grep -c ENOENT reads.log || true)
total=10000

echo "Results:"
echo "  Total reads: $total"
echo "  Errors (ENOENT): $errors"
echo ""

if [[ "$errors" -gt 0 ]]; then
  echo "❌ FAIL: Race condition detected!"
  echo "   $errors requests saw the symlink missing."
  echo ""
  echo "   This is the bug that atomic-deploy fixes."
else
  echo "✓ PASS: No errors detected."
  echo "  (This can happen on lightly loaded systems."
  echo "   Try running under load to trigger the race.)"
fi

# Cleanup
cd ..
rm -rf test-race-dir

echo ""
exit 0
