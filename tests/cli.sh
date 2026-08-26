#!/usr/bin/env bash
#
# Unit tests for CLI argument parsing, exit-code behavior, polling interval
# parsing, and the shell command handed to tmux panes. These tests stub the
# destructive command handlers; they never inspect or touch a real device.
#
# Run directly (BURNINATE_LIB defaults to the repository layout) or as the
# `cli` flake check.

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$here/common.sh"

# --- tmux pane command --------------------------------------------------
#
# Execute the generated shell command using an executable and device path
# containing spaces. This pins the %q quoting across tmux's shell boundary,
# the start -> quiet-check chain, --no-write propagation, and state root.

state_root=/var/lib/burninate-test
tmux_test_dir=${TMPDIR:-/tmp}/burninate-tmux-test-$BASHPID
mkdir -p "$tmux_test_dir"
fake_burninate="$tmux_test_dir/fake burninate"
printf '#!%s\n' "$BASH" >"$fake_burninate"
cat >>"$fake_burninate" <<'EOF'
printf 'state=%s args=' "$BURNINATE_STATE_ROOT"
printf '<%s>' "$@"
printf '\n'
EOF
chmod +x "$fake_burninate"
tmux_pane_command "$fake_burninate" "/dev/fake drive" 900 1 >"$tmux_test_dir/pane-command"
IFS= read -r pane_cmd <"$tmux_test_dir/pane-command"
pane_output=$(bash -c "$pane_cmd")
rm -rf "$tmux_test_dir"
expect "tmux pane command" "$pane_output" "state=$state_root args=<start><--no-write></dev/fake drive>
state=$state_root args=<check><--wait><--interval><900></dev/fake drive>"

# --- CLI dispatch / argument parsing -----------------------------------
#
# Stub the command handlers so we can assert how main() parses start/check/
# tmux options (including options before or after a device) without touching
# a real disk. Each call runs in a subshell so a usage-path exit does not abort
# the harness.

cmd_start() { echo "start dev=$1 dry_run=${2:-} no_write=${3:-}"; }
cmd_check() { echo "check dev=$1 wait=${2:-} interval=${3:-}"; }
cmd_tmux() {
  local session=$1 interval=$2 no_write=$3
  shift 3
  echo "tmux session=$session interval=$interval no_write=$no_write drives=$*"
}
usage() { echo "USAGE"; }

dispatch() { (main "$@") 2>&1; }

expect "start plain"          "$(dispatch start /dev/foo)"            "start dev=/dev/foo dry_run=0 no_write=0"
expect "start --dry-run pre"  "$(dispatch start --dry-run /dev/foo)"  "start dev=/dev/foo dry_run=1 no_write=0"
expect "start --dry-run post" "$(dispatch start /dev/foo --dry-run)"  "start dev=/dev/foo dry_run=1 no_write=0"
expect "start -n"             "$(dispatch start -n /dev/foo)"         "start dev=/dev/foo dry_run=1 no_write=0"
expect "start --no-write"     "$(dispatch start --no-write /dev/foo)" "start dev=/dev/foo dry_run=0 no_write=1"
expect "start option combo"   "$(dispatch start -n --no-write /dev/foo)" "start dev=/dev/foo dry_run=1 no_write=1"
expect "check plain"          "$(dispatch check /dev/foo)"            "check dev=/dev/foo wait=0 interval=900"
expect "check --wait"         "$(dispatch check --wait /dev/foo)"     "check dev=/dev/foo wait=1 interval=900"
expect "check interval"       "$(dispatch check --wait --interval 30m /dev/foo)" "check dev=/dev/foo wait=1 interval=1800"
expect "check interval= form" "$(dispatch check /dev/foo --wait --interval=1h)" "check dev=/dev/foo wait=1 interval=3600"
expect "tmux plain"           "$(dispatch tmux /dev/a /dev/b)" "tmux session=burninate interval=900 no_write=0 drives=/dev/a /dev/b"
expect "tmux options"         "$(dispatch tmux --session rack --interval 30m --no-write /dev/a /dev/b)" "tmux session=rack interval=1800 no_write=1 drives=/dev/a /dev/b"
expect "tmux option equals"   "$(dispatch tmux /dev/a --session=rack --interval=1h)" "tmux session=rack interval=3600 no_write=0 drives=/dev/a"
expect "tmux no drives"       "$(dispatch tmux)" "USAGE"
expect "start no device"      "$(dispatch start)"                     "USAGE"
expect "start two devices"    "$(dispatch start /dev/a /dev/b)"       "USAGE"
expect "start bad option"     "$(dispatch start --bogus /dev/foo)"    "burninate: unknown option: --bogus
USAGE"
expect "interval seconds"     "$(parse_interval 30)"                   "30"
expect "interval minutes"     "$(parse_interval 15m)"                  "900"
expect "interval hours"       "$(parse_interval 2h)"                   "7200"
expect "interval needs wait"  "$(dispatch check --interval 15m /dev/foo)" "burninate: error: --interval requires --wait
note: this does NOT indicate that the drive should be rejected"

# --- exit-code contract ------------------------------------------------

expect "EX_ERROR"  "$EX_ERROR"  "1"
expect "EX_REJECT" "$EX_REJECT" "3"
expect "EX_RETRY"  "$EX_RETRY"  "4"
(die "boom" >/dev/null 2>&1)
expect "die exits EX_ERROR" "$?" "1"
(reject "bad drive" >/dev/null 2>&1)
expect "reject exits EX_REJECT" "$?" "3"

finish_tests
