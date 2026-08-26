#!/usr/bin/env bash
# Shared mechanics for the shell test scripts. This is intentionally small:
# each test file owns its fixtures and assertions. This file only sources the
# code under test and provides the common expectation/reporting functions.

set -u

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lib=${BURNINATE_LIB:-$tests_dir/../burninate.sh}

# shellcheck disable=SC1090
source "$lib"
set +o errexit # the harness tracks failures explicitly, not via exit

failures=0
expect() {
  local label=$1 got=$2 want=$3
  if [[ $got == "$want" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: want [%s] got [%s]\n' "$label" "$want" "$got" >&2
    failures=$((failures + 1))
  fi
}

finish_tests() {
  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "$failures" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}
