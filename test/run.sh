#!/usr/bin/env bash
# Run every test suite in this directory, stopping at the first failure.
set -eu

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for suite in "$TEST_DIR"/*.test.cjs; do
  echo "=== $(basename "$suite") ==="
  node "$suite"
  echo
done

echo "All suites passed."
