#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Exit codes (as defined in the README and help text).
readonly EX_ERROR=1  # operational or usage error (die)
readonly EX_REJECT=3 # the drive failed burn-in, do not use it
readonly EX_RETRY=4  # long self-test still running, run `check` again later

# Program name, used in the usage text and the state directory.
readonly prog="burninate"

# Where to output data. Overridable via BURNINATE_STATE_ROOT.
readonly state_root_default="/var/lib/$prog"
state_root=${BURNINATE_STATE_ROOT:-$state_root_default}

usage() {
  cat >&2 <<EOF
NAME
    $prog -- destructive burn-in for new and spare drives

SYNOPSIS
    $prog start [--dry-run] [--no-write] /dev/disk/by-id/<drive>
    $prog check [--wait] [--interval DURATION] /dev/disk/by-id/<drive>
    $prog tmux [--session NAME] [--interval DURATION] [--no-write] DRIVE...

COMMANDS
    start      start running a full burn-in of the drive (or show what a burn-in
               run would do, if --dry-run is passed).
    check      check if a drive has completed the long SMART self-test started by
               'start', and report the result if it has.
    tmux       run start followed by check --wait for several drives, with one
               vertically stacked pane per drive. Requires tmux on PATH.

OPTIONS
    --dry-run  run pre-flight checks and print what a real burn-in run would
               do, but do not run badblocks and do not start the self-test.
    --no-write run a non-destructive qualification: skip the badblocks surface
               pass (and its confirmation), keeping only the SMART self-tests
               and telemetry. Weaker -- the write and data paths are not
               exercised -- but usable on a drive whose data you must keep.
    --wait     check silently until the long self-test finishes, then print the
               final result. The default polling interval is 15 minutes.
    --interval DURATION
               polling interval for --wait: a positive number with an optional
               s, m, or h suffix (e.g. 30s, 15m, 1h).
    --session NAME
               tmux session name (default: burninate).

ENVIRONMENT VARIABLES
    BURNINATE_STATE_ROOT    directory in which to output data.
                            (default: $state_root_default)

EXIT STATUS
  0            PASS / success
  1            usage or operational error (not root, bad args, would destroy
               existing filesystem, etc...)
  3            REJECT: the drive failed burn-in, do not use it
  4            RETRY: long self-test is still running, run 'check' again later

EOF
}

# Fail execution with an error message (not indicating that a drive is bad)
die() {
  echo "burninate: error: $*" >&2
  echo "note: this does NOT indicate that the drive should be rejected" >&2
  exit "$EX_ERROR"
}

# Reject a drive that failed burn-in.
reject() {
  echo "burninate: REJECT: $*" >&2
  exit "$EX_REJECT"
}

# Print a non-fatal warning. Warnings never change the exit status or reject a
# drive. A warning is printed in order to flag values that are surprising (e.g.
# wear on a supposedly new drive) but which do not indicate that the drive
# should be rejected on their own.
warn() {
  echo "burninate: warning: $*" >&2
}

# Read a numeric counter written to a counters.baseline file by `start`.
# Prints the value, or nothing if the key is absent or non-numeric. Always
# succeeds, so it is safe under errexit in a command substitution.
baseline_counter() {
  local file=$1 key=$2 v
  v=$(grep -m1 "^$key=" "$file" 2>/dev/null | cut -d= -f2 || true)
  [[ $v =~ ^[0-9]+$ ]] && printf '%s' "$v"
  return 0
}

# Parse a positive polling interval with an optional s/m/h suffix. Prints
# seconds, or fails as a usage error. Bare numbers are seconds.
parse_interval() {
  local interval=$1 value unit multiplier
  if [[ ! $interval =~ ^([1-9][0-9]*)([smh]?)$ ]]; then
    die "invalid polling interval '$interval' (expected e.g. 30s, 15m, or 1h)"
  fi
  value=${BASH_REMATCH[1]}
  unit=${BASH_REMATCH[2]}
  case $unit in
    "" | s) multiplier=1 ;;
    m) multiplier=60 ;;
    h) multiplier=3600 ;;
  esac
  printf '%s' "$((value * multiplier))"
}

# Build the shell command for one tmux pane.
#
# `printf %q` preserves arbitrary device paths and state-directory names across
# tmux's shell boundary. The same root shell runs start and the quiet waiter, so
# no second authorization is needed after the multi-day surface pass.
tmux_pane_command() {
  local executable=$1 dev=$2 interval=$3 no_write=${4:-0}
  local start_cmd check_cmd
  local -a start_args=(
    env "BURNINATE_STATE_ROOT=$state_root" "$executable" start
  )
  ((no_write)) && start_args+=(--no-write)
  start_args+=("$dev")

  printf -v start_cmd '%q ' "${start_args[@]}"
  printf -v check_cmd '%q ' \
    env "BURNINATE_STATE_ROOT=$state_root" "$executable" \
    check --wait --interval "$interval" "$dev"
  printf '%s&& %s' "$start_cmd" "$check_cmd"
}

###  Bits for parsing smartctl JSON output using `jq`. ####

smart_json() {
  # -j: JSON output, -x: all logs (a superset of -a).
  #
  # Note: smartctl's exit status is a bitmask that is nonzero even for benign
  # conditions, so to avoid hitting errexit, we suppress errors from smartctl.
  smartctl -j -x "$1" 2>/dev/null || true
}

# Serial and model are unified top-level keys. model falls back through
# the SCSI-specific spellings for older/oddball drives. Callers treat an
# empty result as "unknown".
smart_serial() { jq -r '.serial_number // empty' <<<"$1"; }
smart_model() {
  jq -r '.model_name // .scsi_model_name // .scsi_product // empty' <<<"$1"
}

# Overall health: the boolean .smart_status.passed (true/false), or empty
# if smartctl reported none.
smart_health() { jq -r '.smart_status.passed // empty' <<<"$1"; }

smart_power_hours() { jq -r '.power_on_time.hours // empty' <<<"$1"; }

# Grown-defect counter: SCSI drives report a bare integer element count in
# scsi_grown_defect_list, while ATA drives report it as the
# Reallocated_Sector_Ct raw value (attribute id 5). Either may be absent
# depending on the drive type.
smart_defects() {
  jq -r '
    .scsi_grown_defect_list
    // ([.ata_smart_attributes.table[]? | select(.id == 5) | .raw.value][0])
    // empty' <<<"$1"
}

# Uncorrected errors. For SAS drives, this is the sum of
# total_uncorrected_errors across the SCSI error-counter-log read/write/verify
# pages (a page is present only if it was fetched). For ATA drives, this is the
# raw values of Reported_Uncorrect (id 187) + Offline_Uncorrectable (id 198).
smart_uncorrected() {
  jq -r '
    ([.scsi_error_counter_log | (.read, .write, .verify)
      | .total_uncorrected_errors // empty] | add)
    // ([.ata_smart_attributes.table[]?
         | select(.id == 187 or .id == 198) | .raw.value] | add)
    // empty' <<<"$1"
}

# Endurance used, as a whole-number percent of rated writes (0 = new,
# 100 = rated endurance spent; may exceed 100). SSDs only -- SAS via
# scsi_percentage_used_endurance_indicator, SATA/NVMe via the normalized
# fallbacks. Empty on drives with no wear indicator (spinning HDDs).
smart_endurance_used() {
  jq -r '.scsi_percentage_used_endurance_indicator
    // .endurance_used.current_percent
    // .nvme_smart_health_information_log.percentage_used
    // empty' <<<"$1"
}

# Current temperature and the drive's trip threshold, in Celsius; either may
# be empty.
smart_temp_current() { jq -r '.temperature.current // empty' <<<"$1"; }
smart_temp_trip() { jq -r '.temperature.drive_trip // empty' <<<"$1"; }

# Total SAS phy errors across every port and phy: invalid dwords, loss of dword
# sync, running-disparity errors, and phy-reset problems. A count that climbs
# during burn-in probably indicates a communication issue to the drive (such as
# a bad cable or backplane slot), rather than the drive itself.
#
# Empty on non-SAS transports.
smart_phy_errors() {
  jq -r '
    [ to_entries[] | select(.key | startswith("scsi_sas_port_")) | .value
      | to_entries[] | select(.key | startswith("phy_")) | .value
      | .invalid_dword_count, .loss_of_dword_synchronization_count,
        .running_disparity_error_count, .phy_reset_problem_count ]
    | map(numbers)
    | if length == 0 then empty else add end' <<<"$1"
}

# Corrected read/write errors that needed a reread or rewrite, summed across the
# SCSI error-counter-log pages. This is a soft indication of media degredation,
# and generally it trends up before uncorrected errors appear. Empty on
# ATA/NVMe.
smart_corrected() {
  jq -r '
    [.scsi_error_counter_log | (.read, .write, .verify)
     | .errors_corrected_by_rereads_rewrites // empty]
    | if length == 0 then empty else add end' <<<"$1"
}

# Background medium scan status line (SCSI).
#
# This is informational only. The actionable medium-error results live in a
# separate log (smartctl -l background) that this single -j -x capture does not
# include. Empty on non-SCSI transports.
smart_bms_status() {
  jq -r '.scsi_background_scan.status.string // empty' <<<"$1"
}

# Classify the newest self-test of a given kind as one line:
#   pass | running | absent | "fail\t<detail>"
#
# The kind (second arg, default "long") selects which log rows to consider:
# - "long" means SCSI "Background long" or ATA "Extended offline"
# - "short" means SCSI "Background short" or ATA "Short offline".
#
# For SCSI (i.e. SAS) drives, the log is formatted as a flat list of keys like
# 'scsi_self_test_<n>', where higher values of 'n' are more recent self-tests.
# For each entry, 'code.string' indicates which self-test kind was run. The
# outcome is indicated by the 'result.value' key, with 0 meaning a clean pass,
# 15 meaning in progress (also indicated' by self_test_in_progress), and
# anything else is a failure. We select the newest 'n' value where the
# 'code.string' indicaes the desired type of test.
#
# For ATA drives, entries live under
# 'ata_smart_self_test_log.{extended,standard}.table' (whichever the drive
# supports), newest first. We pick the newest entry whose 'type.string'
# indicates the desired test type. The 'status.value' field inciates the
# outcome:
# - high nibble 0x0 is a clean pass,
# - 0xf is in progress.
# A freshly-started test may not have a log row yet, so the current execution
# status (ata_smart_data.self_test.status) is consulted first. This is not
# kind-aware, but we only use it to determine if a self test is running. Note
# that an in-progress ATA log row carries a misleading status.passed:true, so
# we key on status.value, never on passed.
smart_selftest_status() {
  local kind=${2:-long} scsi_pat ata_pat
  case $kind in
    long) scsi_pat=long; ata_pat=extended ;;
    short) scsi_pat=short; ata_pat=short ;;
    *) die "internal error: unknown self-test kind '$kind'" ;;
  esac
  jq -r --arg scsi_pat "$scsi_pat" --arg ata_pat "$ata_pat" '
    def scsi_sel:
      [ to_entries[]
        | select(.key | startswith("scsi_self_test_"))
        | { i: (.key | ltrimstr("scsi_self_test_") | tonumber), v: .value } ]
      | sort_by(.i) | map(.v)
      | map(select(.code.string | test($scsi_pat; "i")))
      | first;
    def ata_current_running:
      ((.ata_smart_data.self_test.status.string // "") | test("in progress"; "i"));
    def ata_sel:
      ( .ata_smart_self_test_log.extended.table
        // .ata_smart_self_test_log.standard.table // [] )
      | map(select(.type.string | test($ata_pat; "i")))
      | first;
    if (.device.protocol == "SCSI") then
      (scsi_sel) as $e
      | if   $e == null                          then "absent"
        elif ($e.self_test_in_progress == true)   then "running"
        elif ($e.result.value == 0)               then "pass"
        else  "fail\t" + ($e.result.string // "unknown")
        end
    elif (.device.protocol == "ATA") then
      (ata_sel) as $e
      | if   ata_current_running                            then "running"
        elif $e == null                                     then "absent"
        elif (((($e.status.value // 0) / 16) | floor) == 15) then "running"
        elif (((($e.status.value // 0) / 16) | floor) == 0)  then "pass"
        else  "fail\t" + ($e.status.string // "unknown")
        end
    else
      "absent"
    end' <<<"$1"
}

# Poll a running self-test of the given kind (default "long") to completion,
# refreshing the SMART capture each interval. Echoes the terminal test outcome
# line (pass/absent/"fail\t...") on stdout.
#
# This polling is bounded by a timeout so a drive that under-reports or stalls
# cannot wedge the caller forever. The timeout elapsing is the only circiumsance
# under which this returns a non-zero status code.
smart_await_selftest() {
  local dev=$1 kind=${2:-long} timeout=${3:-1200} interval=15
  local waited=0 json status
  while :; do
    json=$(smart_json "$dev")
    status=$(smart_selftest_status "$json" "$kind")
    [[ ${status%%$'\t'*} != running ]] && break
    if ((waited >= timeout)); then
      return 1
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  printf '%s\n' "$status"
}

# Best-effort "N% of test remaining" line for an in-progress test.
# SCSI does not report a percentage, so this prints nothing there.
smart_remaining() {
  jq -r '
    ( ( .ata_smart_self_test_log.extended.table
        // .ata_smart_self_test_log.standard.table // [] )[0].status.remaining_percent
      // .ata_smart_data.self_test.status.remaining_percent // empty )
    | "  ~\(.)% of test remaining"' <<<"$1"
}

cmd_start() {
  local dev=$1 dry_run=${2:-0} no_write=${3:-0}

  [[ $EUID -eq 0 ]] || die "must be run as root"
  [[ -e $dev ]] || die "$dev: no such device"
  [[ -b $dev ]] || die "$dev: not a block device"

  local real
  real=$(realpath "$dev")

  local devtype
  devtype=$(lsblk -ndo TYPE "$dev" || true)
  [[ $devtype == disk ]] || die "$dev: not a whole disk (TYPE=${devtype:-?})"

  ### safety checks ###

  # Nothing mounted from the disk or any of its partitions.
  if lsblk -no MOUNTPOINTS "$dev" | grep -q .; then
    lsblk -o NAME,TYPE,MOUNTPOINTS "$dev" >&2
    die "$dev: something on this disk is mounted!"
  fi

  # No holders: refuse if the disk or a partition is claimed by md/dm/
  # LUKS/LVM. ZFS members have no holders, hence the separate pool gate
  # below.
  local kname
  while IFS= read -r kname; do
    local holders=("/sys/class/block/$kname/holders/"*)
    if [[ -e "${holders[0]}" ]]; then
      die "$dev: /dev/$kname is claimed by: ${holders[*]##*/}"
    fi
  done < <(lsblk -lno KNAME "$dev")

  # Not a member of any imported zpool, checked by both resolved device
  # path and WWN. This profile is not ZFS-specific, so zpool is probed
  # from PATH rather than pulled into runtimeInputs.
  if command -v zpool >/dev/null 2>&1; then
    local zstatus wwn
    zstatus=$(zpool status -LP 2>/dev/null || true)
    if grep -qF "$real" <<<"$zstatus"; then
      die "$dev ($real) appears in 'zpool status'; NOT touching a pool member"
    fi
    wwn=$(lsblk -ndo WWN "$dev" || true)
    wwn=${wwn#0x}
    if [[ -n $wwn ]] && grep -qiF "$wwn" <<<"$zstatus"; then
      die "$dev (WWN $wwn) appears in 'zpool status'; NOT touching a pool member"
    fi
  fi

  echo "=== $dev"
  echo "--- existing signatures (wipefs -n; expect none, or stale ones):"
  wipefs -n "$dev"
  local size
  size=$(blockdev --getsize64 "$dev")
  echo "--- size: $size bytes"
  echo "    (verify byte-identical to the fleet size in the host README;"
  echo "    that is what makes drives interchangeable for spare attach)"

  ### baseline + fail-fast ###

  local smart_out model serial
  smart_out=$(smart_json "$dev")
  model=$(smart_model "$smart_out")
  serial=$(smart_serial "$smart_out")
  [[ -n $serial ]] || die "$dev: could not read a serial number via smartctl"

  local defects uncorrected hours health
  local endurance temp temp_trip phy_errors corrected bms
  defects=$(smart_defects "$smart_out")
  uncorrected=$(smart_uncorrected "$smart_out")
  hours=$(smart_power_hours "$smart_out")
  health=$(smart_health "$smart_out")
  endurance=$(smart_endurance_used "$smart_out")
  temp=$(smart_temp_current "$smart_out")
  temp_trip=$(smart_temp_trip "$smart_out")
  phy_errors=$(smart_phy_errors "$smart_out")
  corrected=$(smart_corrected "$smart_out")
  bms=$(smart_bms_status "$smart_out")

  echo
  echo "  model:  ${model:-unknown}"
  echo "  serial: $serial"
  echo "  health: ${health:-unknown}"
  echo "  grown defects / reallocated: ${defects:-not reported}"
  echo "  uncorrected errors:          ${uncorrected:-not reported}"
  echo "  power-on hours:              ${hours:-unknown}"
  [[ -n $endurance ]] && echo "  endurance used:              ${endurance}%"
  [[ -n $temp ]] && echo "  temperature:                 ${temp}C${temp_trip:+ (trip: ${temp_trip}C)}"
  [[ -n $corrected ]] && echo "  corrected (reread/rewrite):  $corrected"
  [[ -n $phy_errors ]] && echo "  SAS phy errors:              $phy_errors"
  [[ -n $bms ]] && echo "  background media scan:       $bms"
  echo

  # Fail fast if the drive's SMART already reports that it's damaged rather than
  # spending ~1.5 days writing to it. Only actual damage is a hard reject:
  # health explicitly failed, or a nonzero defect/uncorrected count. Absent
  # counters do not indicate a problem, since HDDs have no endurance indicator,
  # while NVMe drives have no SCSI error log.
  local -a baseline_problems=()
  [[ $health == false ]] &&
    baseline_problems+=("SMART overall-health self-assessment already reports FAILURE")
  [[ -n $defects && $defects -gt 0 ]] &&
    baseline_problems+=("grown defects / reallocated already nonzero: $defects")
  [[ -n $uncorrected && $uncorrected -gt 0 ]] &&
    baseline_problems+=("uncorrected errors already nonzero: $uncorrected")
  if ((${#baseline_problems[@]} > 0)); then
    local bp
    for bp in "${baseline_problems[@]}"; do
      echo "  - $bp" >&2
    done
    reject "baseline SMART is already dirty; send this drive back rather than burning it in"
  fi

  # Wear/age signals: these are just a warning, since they are surprising on a
  # genuinely new drive, but expected on a used spare being re-qualified.
  [[ -n $endurance && $endurance -gt 0 ]] &&
    warn "endurance indicator already ${endurance}% used (expected for a used spare, surprising for a new drive)"
  [[ -n $temp && -n $temp_trip && $temp -ge $temp_trip ]] &&
    warn "temperature ${temp}C is at or above the drive's trip threshold ${temp_trip}C"

  if ((dry_run)); then
    echo "=== DRY RUN: nothing will be written to $dev ==="
    echo "  resolved:  $dev -> $real"
    echo "  size:      $size bytes"
    echo "  state dir: $state_root/$serial"
    echo
    echo "Would run:"
    echo "  1. short SMART self-test (fail-fast gate)"
    if ((no_write)); then
      echo "  2. surface pass SKIPPED (--no-write)"
    else
      echo "  2. after serial confirmation: badblocks -b 8192 -wsv -t random \\"
      echo "       -o $state_root/$serial/badblocks.txt $dev"
    fi
    echo "  3. smartctl -t long $dev"
    exit "$EX_OKAY"
  fi

  # Fail-fast short self-test (~1-2 min). This may catch faults not reported by
  # the baseline health status check above, allowing us to rejects a DOA drive
  # before the surface pass. Runs before the confirmation prompt so a dead drive
  # never asks the operator to commit.
  echo "Running short SMART self-test (fail-fast gate; ~1-2 min)..."
  smartctl -t short "$dev" >/dev/null || die "failed to start short self-test"
  local short_status short_state
  short_status=$(smart_await_selftest "$dev" short 1200) ||
    die "short self-test did not finish within 20m; investigate before burning in"
  short_state=${short_status%%$'\t'*}
  case $short_state in
    pass) echo "Short self-test passed." ;;
    absent) reject "short self-test left no result in the log; cannot qualify this drive" ;;
    *) reject "short self-test did not pass: ${short_status#*$'\t'}" ;;
  esac

  ### burn-in ###

  local dir=$state_root/$serial

  if ((no_write)); then
    echo "--no-write: skipping the destructive surface pass. This is a"
    echo "non-destructive re-qualification (SMART self-tests and read-only"
    echo "telemetry only). Write and data paths are NOT exercised."
  else
    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! This will DESTROY ALL DATA on $dev.                            !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
    echo "warning: The write and verify burn-in pass may take over a day to"
    echo "         complete on an HDD. If you are not running this script under"
    echo "         tmux(1) or screen(1), stop now and start over."
    echo
    local reply
    read -r -p "Type the drive's serial number to proceed: " reply ||
      die "aborted"
    [[ $reply == "$serial" ]] || die "serial mismatch; aborting"
  fi

  mkdir -p "$dir"
  printf '%s\n' "$smart_out" >"$dir/baseline.json"
  {
    echo "device=$dev"
    echo "date=$(date -Is)"
    echo "defects=$defects"
    echo "uncorrected=$uncorrected"
    echo "phy_errors=$phy_errors"
    echo "corrected=$corrected"
  } >"$dir/counters.baseline"
  echo "Baseline saved to $dir/baseline.json"
  echo

  if ((no_write)); then
    echo "Skipping badblocks surface pass (--no-write)."
  else
    echo "Starting full-surface write+verify: badblocks -b 8192 -wsv -t random"
    badblocks -b 8192 -wsv -t random -o "$dir/badblocks.txt" "$dev" ||
      reject "badblocks failed (I/O error?)"
    if [[ -s "$dir/badblocks.txt" ]]; then
      reject "badblocks found $(wc -l <"$dir/badblocks.txt") bad blocks (list: $dir/badblocks.txt)"
    fi
    echo "Surface pass clean: 0 bad blocks."
  fi

  smartctl -t long "$dev" || die "failed to start long self-test"
  cat <<EOF

Long self-test started. This will run for a long time (see the estimate from
smartctl), and will continue running once this shell has exited.

Once it is done, run:

  burninate check --wait $dev

EOF
}

cmd_check() {
  local dev=$1 wait=${2:-0} interval=${3:-900}

  [[ $EUID -eq 0 ]] || die "must be run as root"
  [[ -b $dev ]] || die "$dev is not a block device"

  local smart_out serial
  smart_out=$(smart_json "$dev")
  serial=$(smart_serial "$smart_out")
  [[ -n $serial ]] || die "$dev: could not read a serial number via smartctl"

  local dir=$state_root/$serial
  [[ -f "$dir/baseline.json" ]] ||
    die "no baseline for serial $serial; run 'burninate start' first"

  # Poll quietly when requested. We re-check the serial after every sleep to
  # make sure we are still polling the same drive, to avoid comparing against a
  # baseline captured from a different device. This *should* never happen if the
  # drive was named using a /dev/disk/by-id path, but we can't ensure that's how
  # the caller passed it to us...
  local status state polled_serial
  while :; do
    status=$(smart_selftest_status "$smart_out")
    state=${status%%$'\t'*}
    [[ $state != running ]] && break

    if ((!wait)); then
      echo "Long self-test is still running on $dev; check again later."
      smart_remaining "$smart_out"
      exit "$EX_RETRY"
    fi

    sleep "$interval"
    smart_out=$(smart_json "$dev")
    polled_serial=$(smart_serial "$smart_out")
    [[ -n $polled_serial ]] ||
      die "$dev: could not read a serial number via smartctl while waiting"
    [[ $polled_serial == "$serial" ]] ||
      die "$dev: serial changed while waiting ($serial -> $polled_serial)"
  done

  # Only terminal results are persisted. In --wait mode this is also the
  # first normal output, so a pane keeps showing the tail of `start` until
  # the drive has actually finished its self-test.
  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  printf '%s\n' "$smart_out" >"$dir/check-$stamp.json"
  echo "Saved smartctl output to $dir/check-$stamp.json"

  local detail=""
  [[ $status == *$'\t'* ]] && detail=${status#*$'\t'}

  local -a problems=()

  case $state in
    pass) : ;;
    absent) problems+=("no long self-test found in the self-test log") ;;
    fail) problems+=("long self-test did not complete cleanly: ${detail:-unknown}") ;;
    *) problems+=("could not classify the self-test log (state: $state)") ;;
  esac

  # Overall SMART health self-assessment: the boolean .smart_status.passed.
  local health
  health=$(smart_health "$smart_out")
  if [[ $health == false ]]; then
    problems+=("SMART overall-health self-assessment reports FAILURE")
  fi

  local base_defects cur_defects
  base_defects=$(baseline_counter "$dir/counters.baseline" defects)
  cur_defects=$(smart_defects "$smart_out")
  if [[ -n $cur_defects && -n $base_defects ]]; then
    if (( cur_defects > base_defects )); then
      problems+=("grown defect list grew: $base_defects -> $cur_defects")
    fi
  elif [[ -n $cur_defects ]]; then
    if (( cur_defects > 0 )); then
      problems+=("grown defect list is nonzero ($cur_defects), no baseline to compare")
    fi
  fi

  # Absolute, not relative to baseline: spares must start clean.
  local cur_unc
  cur_unc=$(smart_uncorrected "$smart_out")
  if [[ -n $cur_unc ]] && (( cur_unc > 0 )); then
    problems+=("uncorrected errors: $cur_unc (must be 0)")
  fi

  # Check for warnings that do not indicate the drive should be rejected. A
  # rising SAS phy error count usually means a bad cable or backplane slot, not
  # a bad drive, Rising corrected (reread/rewrite) errors are early media wear
  # that shows up before uncorrected errors do.
  local base_phy cur_phy base_corrected cur_corrected
  base_phy=$(baseline_counter "$dir/counters.baseline" phy_errors)
  cur_phy=$(smart_phy_errors "$smart_out")
  if [[ -n $cur_phy && -n $base_phy ]] && (( cur_phy > base_phy )); then
    warn "SAS phy errors rose $base_phy -> $cur_phy (probably a backplane or cable issue, not a bad drive)"
  fi
  base_corrected=$(baseline_counter "$dir/counters.baseline" corrected)
  cur_corrected=$(smart_corrected "$smart_out")
  if [[ -n $cur_corrected && -n $base_corrected ]] && (( cur_corrected > base_corrected )); then
    warn "corrected (reread/rewrite) errors rose $base_corrected -> $cur_corrected (early media wear)"
  fi

  local endurance temp
  endurance=$(smart_endurance_used "$smart_out")
  temp=$(smart_temp_current "$smart_out")

  echo
  if (( ${#problems[@]} == 0 )); then
    echo "PASS: $dev (serial $serial)"
    echo "  long self-test completed without error"
    echo "  grown defects / reallocated: ${cur_defects:-not reported} (baseline: ${base_defects:-not recorded})"
    echo "  uncorrected errors: ${cur_unc:-not reported}"
    [[ -n $endurance ]] && echo "  endurance used: ${endurance}%"
    [[ -n $temp ]] && echo "  temperature: ${temp}C"
    echo "Label the drive with today's date and its power-on hours, then shelve it."
    exit 0
  fi

  echo "FAIL: $dev (serial $serial); reject this drive:" >&2
  local p
  for p in "${problems[@]}"; do
    echo "  - $p" >&2
  done
  exit "$EX_REJECT"
}

cmd_tmux() {
  local session=$1 interval=$2 no_write=$3
  shift 3
  local -a drives=("$@")

  [[ $EUID -eq 0 ]] ||
    die "the tmux subcommand must be run as root (use 'sudo burninate tmux ...')"
  command -v tmux >/dev/null 2>&1 ||
    die "the tmux subcommand requires tmux on PATH"
  [[ $session =~ ^[A-Za-z0-9_.-]+$ ]] ||
    die "invalid tmux session name '$session' (use letters, digits, '.', '_', or '-')"
  tmux has-session -t "=$session" 2>/dev/null &&
    die "tmux session '$session' already exists (attach with: sudo tmux attach-session -t $session)"

  local dev
  for dev in "${drives[@]}"; do
    [[ -e $dev ]] || die "$dev: no such device"
    [[ -b $dev ]] || die "$dev: not a block device"
  done

  local executable command pane
  executable=$(command -v -- "$0") || die "could not locate the burninate executable"
  executable=$(realpath "$executable")

  command=$(tmux_pane_command "$executable" "${drives[0]}" "$interval" "$no_write")
  pane=$(tmux new-session -d -P -F '#{pane_id}' \
    -s "$session" -n drives) ||
    die "failed to create tmux session '$session'"

  # Configure the window before starting work, so even an immediate reject
  # leaves its pane and output available for review.
  tmux set-window-option -t "$session:drives" remain-on-exit on
  tmux set-window-option -t "$session:drives" pane-border-status top
  tmux set-window-option -t "$session:drives" \
    pane-border-format '#{pane_index}: #{pane_title}'
  tmux select-pane -t "$pane" -T "$(basename "${drives[0]}")"
  tmux respawn-pane -k -t "$pane" "$command" ||
    die "failed to start ${drives[0]} in tmux session '$session'"

  for dev in "${drives[@]:1}"; do
    command=$(tmux_pane_command "$executable" "$dev" "$interval" "$no_write")
    pane=$(tmux split-window -d -v -P -F '#{pane_id}' \
      -t "$session:drives" "$command") ||
      die "failed to add $dev to tmux session '$session'"
    tmux select-pane -t "$pane" -T "$(basename "$dev")"
    tmux select-layout -t "$session:drives" even-vertical >/dev/null
  done

  if [[ -n ${TMUX:-} ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session" ||
      die "failed to attach; retry with: sudo tmux attach-session -t $session"
  fi
}

main() {
  local cmd=${1:-}
  case $cmd in
    start)
      shift
      local dry_run=0 no_write=0
      local -a args=()
      local a
      for a in "$@"; do
        case $a in
          --dry-run | -n) dry_run=1 ;;
          --no-write | --no-badblocks) no_write=1 ;;
          --) ;;
          -*)
            echo "burninate: unknown option: $a" >&2
            usage
            exit 1
            ;;
          *) args+=("$a") ;;
        esac
      done
      if [[ ${#args[@]} -ne 1 ]]; then
        usage
        exit 1
      fi
      cmd_start "${args[0]}" "$dry_run" "$no_write"
      ;;
    check)
      shift
      local wait=0 interval=900 interval_set=0
      local -a args=()
      while (($#)); do
        case $1 in
          --wait)
            wait=1
            shift
            ;;
          --interval)
            [[ $# -ge 2 ]] || die "--interval requires a duration"
            interval=$(parse_interval "$2")
            interval_set=1
            shift 2
            ;;
          --interval=*)
            interval=$(parse_interval "${1#*=}")
            interval_set=1
            shift
            ;;
          --)
            shift
            args+=("$@")
            break
            ;;
          -*)
            echo "burninate: unknown option: $1" >&2
            usage
            exit "$EX_ERROR"
            ;;
          *)
            args+=("$1")
            shift
            ;;
        esac
      done
      if [[ ${#args[@]} -ne 1 ]]; then
        usage
        exit "$EX_ERROR"
      fi
      ((interval_set && !wait)) && die "--interval requires --wait"
      cmd_check "${args[0]}" "$wait" "$interval"
      ;;
    tmux)
      shift
      local session=burninate interval=900 no_write=0
      local -a drives=()
      while (($#)); do
        case $1 in
          --session)
            [[ $# -ge 2 ]] || die "--session requires a name"
            session=$2
            shift 2
            ;;
          --session=*)
            session=${1#*=}
            shift
            ;;
          --interval)
            [[ $# -ge 2 ]] || die "--interval requires a duration"
            interval=$(parse_interval "$2")
            shift 2
            ;;
          --interval=*)
            interval=$(parse_interval "${1#*=}")
            shift
            ;;
          --no-write | --no-badblocks)
            no_write=1
            shift
            ;;
          --)
            shift
            drives+=("$@")
            break
            ;;
          -*)
            echo "burninate: unknown option: $1" >&2
            usage
            exit "$EX_ERROR"
            ;;
          *)
            drives+=("$1")
            shift
            ;;
        esac
      done
      if [[ ${#drives[@]} -eq 0 ]]; then
        usage
        exit "$EX_ERROR"
      fi
      cmd_tmux "$session" "$interval" "$no_write" "${drives[@]}"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

# Dispatch only when executed directly. Sourcing this file (e.g. from the
# parsing test) then defines the helper functions without running the CLI.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
