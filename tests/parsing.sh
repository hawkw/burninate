#!/usr/bin/env bash
#
# Unit tests for the smartctl-JSON parsing and self-test outcome extraction
# helpers in burninate.sh.
#
# Every parsing is a pure function of a `smartctl -j` JSON document, so they are
# testable without having to run `smartctl` commands against any real hardware.
# We source burninate.sh, and its `main` is guarded by a BASH_SOURCE check, so
# sourcing defines the functions without running the CLI. Then, we call the
# parsing functions under test with sample JSON as their stdin.
#
# Two kinds of fixtures:
#
#   1. samples/*.json: real `smartctl -j -x` dumps from ATA (a SATA SSD),
#      SCSI (a SAS HDD and a SAS SSD), and NVMe drives. This way, we are testing
#      against representative smartctl output from various kinds of drives, for
#      which smartctl will output differently-shaped JSON.
#
#   2. Synthetic self-test logs built inline with jq. None of the real
#      dumps have a self-test in their log at the time that the samples were
#      captured, so the pass/running/fail detection paths are exercised by
#      synthetic data. This is synthesized based on he expected smartmontools
#      7.x JSON output:
#      - SCSI (SAS) drives emits flat sibling keys 'scsi_self_test_<n>' at the
#        top level of the JSON object, with the newest first, and the highest
#        value of `n` representing the latest self test. Within these objects,
#        'result.value' 0 indicates a pass, while 15 indicates the test is in
#        progress.
#      - ATA nests entries under
#        'ata_smart_self_test_log.{extended,standard}.table'. Within that,
#        'status.value''s high nibble indicates the status, with 0x0 meaning a
#         pass, and 0xf meaning in progress.
#
# Run directly (BURNINATE_LIB / BURNINATE_SAMPLES default to the repo
# layout) or as the `parsing` flake check.

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$here/common.sh"
samples=${BURNINATE_SAMPLES:-$here/samples}

sample() { cat "$samples/$1.json"; }

# --- real dumps: field extraction across transports --------------------

j=$(sample nvme-ssd)
expect "nvme serial"  "$(smart_serial "$j")"           "S640NX0Y706128"
expect "nvme model"   "$(smart_model "$j")"            "SAMSUNG MZVL2512HCJQ-00BH7"
expect "nvme health"  "$(smart_health "$j")"           "true"
expect "nvme hours"   "$(smart_power_hours "$j")"      "39"
expect "nvme defects" "$(smart_defects "$j")"          "" # NVMe reports neither
expect "nvme unc"     "$(smart_uncorrected "$j")"      ""
expect "nvme verdict" "$(smart_selftest_status "$j")" "absent"

j=$(sample sas-hdd)
expect "sas-hdd serial"  "$(smart_serial "$j")"           "2CHNGUYP"
expect "sas-hdd model"   "$(smart_model "$j")"            "WDC WUH721816AL5204"
expect "sas-hdd health"  "$(smart_health "$j")"           "true"
expect "sas-hdd hours"   "$(smart_power_hours "$j")"      "1470"
expect "sas-hdd defects" "$(smart_defects "$j")"          "0"
expect "sas-hdd unc"     "$(smart_uncorrected "$j")"      "0"
expect "sas-hdd verdict" "$(smart_selftest_status "$j")" "absent"

j=$(sample sas-ssd)
expect "sas-ssd serial"  "$(smart_serial "$j")"           "Z87130AR0000822150Z3"
expect "sas-ssd defects" "$(smart_defects "$j")"          "0"
expect "sas-ssd unc"     "$(smart_uncorrected "$j")"      "0" # no verify page; sums read+write
expect "sas-ssd verdict" "$(smart_selftest_status "$j")" "absent"

j=$(sample sata-ssd)
expect "sata serial"  "$(smart_serial "$j")"           "S3PZNF0JA28518H"
expect "sata model"   "$(smart_model "$j")"            "Samsung SSD 850 EVO 250GB"
expect "sata hours"   "$(smart_power_hours "$j")"      "7810"
expect "sata defects" "$(smart_defects "$j")"          "0"
expect "sata unc"     "$(smart_uncorrected "$j")"      "0" # id 187 by number, not name
expect "sata verdict" "$(smart_selftest_status "$j")" "absent"

# --- SSD / SAS telemetry extraction ------------------------------------
# Endurance, temperature, SAS phy errors, corrected-error trend, and BMS
# status -- each present only on the transports that report it, so the
# "empty on the wrong transport" cases are part of the contract.

j=$(sample sas-hdd)
expect "sas-hdd endurance" "$(smart_endurance_used "$j")" ""  # HDD: no wear indicator
expect "sas-hdd phy"       "$(smart_phy_errors "$j")"     "0"
expect "sas-hdd corrected" "$(smart_corrected "$j")"      "0"
expect "sas-hdd bms"       "$(smart_bms_status "$j")"     "waiting until BMS interval timer expires"

j=$(sample sas-ssd)
expect "sas-ssd endurance" "$(smart_endurance_used "$j")" "0"
expect "sas-ssd temp"      "$(smart_temp_current "$j")"   "31"
expect "sas-ssd trip"      "$(smart_temp_trip "$j")"      "70"
expect "sas-ssd phy"       "$(smart_phy_errors "$j")"     "0"
expect "sas-ssd corrected" "$(smart_corrected "$j")"      "14" # nonzero reread/rewrite at baseline

j=$(sample sata-ssd)
expect "sata endurance"    "$(smart_endurance_used "$j")" "0"
expect "sata temp"         "$(smart_temp_current "$j")"   "26"
expect "sata phy"          "$(smart_phy_errors "$j")"     ""  # ATA: no SAS phy counters
expect "sata corrected"    "$(smart_corrected "$j")"      ""

j=$(sample nvme-ssd)
expect "nvme endurance"    "$(smart_endurance_used "$j")" "0"  # via nvme_smart_health_information_log
expect "nvme temp"         "$(smart_temp_current "$j")"   "33"

# --- synthetic self-test logs: verdict classification ------------------
#
# selftest_state strips any "\t<detail>" suffix so we assert on the leading
# token; inject builds a fixture by applying a jq patch to a base dump.

selftest_state() {
  local v
  v=$(smart_selftest_status "$1" "${2:-long}")
  printf '%s' "${v%%$'\t'*}"
}
inject() { jq -c "$2" <"$samples/$1.json"; }

# SCSI: newest "long" test decides; a short test alone reads as absent.
expect "scsi pass" \
  "$(selftest_state "$(inject sas-hdd '. + {scsi_self_test_0:{code:{string:"Background long"},result:{value:0,string:"Completed"}}}')")" \
  "pass"
expect "scsi running" \
  "$(selftest_state "$(inject sas-hdd '. + {scsi_self_test_0:{code:{string:"Background long"},result:{value:15,string:"Self test in progress ..."},self_test_in_progress:true}}')")" \
  "running"
expect "scsi fail" \
  "$(selftest_state "$(inject sas-hdd '. + {scsi_self_test_0:{code:{string:"Background long"},result:{value:5,string:"Completed, segment failed"}}}')")" \
  "fail"
expect "scsi short-only -> absent" \
  "$(selftest_state "$(inject sas-hdd '. + {scsi_self_test_0:{code:{string:"Background short"},result:{value:0}}}')")" \
  "absent"
expect "scsi newest-of-two -> pass" \
  "$(selftest_state "$(inject sas-hdd '. + {scsi_self_test_1:{code:{string:"Background long"},result:{value:5}},scsi_self_test_0:{code:{string:"Background long"},result:{value:0}}}')")" \
  "pass"

# ATA: newest "extended" entry decides; a fresh test with no log row yet is
# caught via the current execution status (ata_smart_data.self_test.status).
expect "ata pass" \
  "$(selftest_state "$(inject sata-ssd '.ata_smart_self_test_log.extended.table=[{type:{string:"Extended offline"},status:{value:0,string:"Completed without error",passed:true}}]')")" \
  "pass"
expect "ata running (log row)" \
  "$(selftest_state "$(inject sata-ssd '.ata_smart_self_test_log.extended.table=[{type:{string:"Extended offline"},status:{value:241,string:"Self-test routine in progress",remaining_percent:10,passed:true}}]')")" \
  "running"
expect "ata running (current status, no row)" \
  "$(selftest_state "$(inject sata-ssd '.ata_smart_data.self_test.status={value:249,string:"Self-test routine in progress...",remaining_percent:90}')")" \
  "running"
expect "ata fail" \
  "$(selftest_state "$(inject sata-ssd '.ata_smart_self_test_log.extended.table=[{type:{string:"Extended offline"},status:{value:121,string:"Completed: read failure",passed:false},lba:123}]')")" \
  "fail"

# The short kind (used by the start fail-fast gate) selects a different
# set of rows: SCSI "Background short" / ATA "Short offline". A long test
# alone must not satisfy a short-kind query, and vice versa.
expect "scsi short pass" \
  "$(selftest_state "$(inject sas-hdd '. + {scsi_self_test_0:{code:{string:"Background short"},result:{value:0}}}')" short)" \
  "pass"
expect "scsi short running" \
  "$(selftest_state "$(inject sas-hdd '. + {scsi_self_test_0:{code:{string:"Background short"},result:{value:15},self_test_in_progress:true}}')" short)" \
  "running"
expect "scsi short fail" \
  "$(selftest_state "$(inject sas-hdd '. + {scsi_self_test_0:{code:{string:"Background short"},result:{value:3,string:"unknown error"}}}')" short)" \
  "fail"
expect "scsi long-only, asked short -> absent" \
  "$(selftest_state "$(inject sas-hdd '. + {scsi_self_test_0:{code:{string:"Background long"},result:{value:0}}}')" short)" \
  "absent"
expect "ata short pass" \
  "$(selftest_state "$(inject sata-ssd '.ata_smart_self_test_log.extended.table=[{type:{string:"Short offline"},status:{value:0,string:"Completed without error",passed:true}}]')" short)" \
  "pass"
expect "ata short-only, asked long -> absent" \
  "$(selftest_state "$(inject sata-ssd '.ata_smart_self_test_log.extended.table=[{type:{string:"Short offline"},status:{value:0,string:"Completed without error",passed:true}}]')" long)" \
  "absent"



finish_tests
