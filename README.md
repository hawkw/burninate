# burninate

burninate breaks your hard drives *now*, so that they don't break *later*.

This is a destructive burn-in script for newly acquired storage devices. It aims
to help you avoid getting caught on the bad side of the [bathtub curve] when a
new disk arrives defective. The `burninate start` command records a baseline of
a drive's SMART data, runs `badblocks` to write and verify every sector on the
disk, and then runs a long SMART self-test. Once this completes, you can use
`burninate check` to determine if any defects were detected.

The point of this testing is to cause drives which have defects that make them
likely to fall victim to "infant mortality" to fail *now*, by writing data you
don't actually care about, instead of *later*, once you've actually stored data
on them. This is particularly important for spares (whether hot or cold): since
nothing is actively using a spare, it's entirely possible that the spare drive
is totally dead, and you won't find out until you actually try to use it to
replace a failed drive. By burninating your cold spares before putting them back
on the shelf, you can regain some confidence that the drive isn't going to die
as soon as it's used...or RMA it while it's still under warranty.

> [!CAUTION]
> DANGER DANGER DANGER: burninating a storage device will DESTROY ANY DATA
> already on that device! Only run this on drives *before* they have actually
> been used to store data!

[bathtub curve]: https://en.wikipedia.org/wiki/Bathtub_curve

## Requirements

This script requires a Linux system with the following runtime dependencies:

- `smartctl(8)`, from [smartmontools],
- `badblocks(8)`, from [e2fsprogs],
- `lsblk(8)`,
- `wipefs(8)`,
- `blockdev(8)`,
- [`jq(1)`][jq].

If there's a `zpool(8)` command on the `PATH`, it will also use it to check if
a disk is currently part of a zpool to prevent burninating actively used drives.
If no `zpool(8)` can be found, this script assumes that ZFS is not in use.

The [`burninate tmux`](#burninate-tmux) subcommand additionally requires a 
`tmux(1)` binary on the `PATH`.

For [nix](https://nixos.org) users, this script is packaged as a Nix flake,
which will ensure that the script runs with the requisite dependencies on the
`PATH`.

[smartmontools]: https://www.smartmontools.org/
[e2fsprogs]: https://e2fsprogs.sourceforge.net/
[jq]: https://jqlang.org/

## Usage

- [`burninate start <DRIVE>`](#burninate-start): start burning in a drive
- [`burninate check <DRIVE>`](#burninate-check): check if a burn-in has 
  completed
- [`burninate tmux <DRIVES...>`](#burninate-tmux): burn-in multiple drives in a
  single `tmux(1)` session

> [!NOTE]
> Always address drives by a stable `/dev/disk/by-id/...` path, rather than
> `/dev/sdX`. `/dev/disk/by-id` paths are stable across system restarts or disk
> hotplug, while `/dev/sdX` paths may change arbitrarily.

### `burninate start`

```console
burninate start [--dry-run] [--no-write] /dev/disk/by-id/<DRIVE>
```

Start burning in a drive.

> [!IMPORTANT]
> Always run this command using `tmux(1)`, `screen(1)`, or another mechanism of
> ensuring that the process will continue if your session is interrupted.

Burning in a large hard drive may take multiple days. The process will complete
much faster on SSDs, but may still take on the order of several hours.

`start` runs, in order:

1. **Preflight safety checks.** Before starting a burn-in, the script makes
   several checks to ensure that it's okay to do so. In particular, we ensure
   that:
    - you're running as root,
    - the provided device is an entire disk, not a partition,
    - the disk appears to not be in use: no mounted partitions, no
      device-mapper/md/LUKS holders, and (if there's a `zpool` binary present)
      not a member of any imported ZFS pool,
    - no filesystem signatures present (checked by `wipefs -n`).
2. **Baseline health data and fail-fast.** The full `smartctl -j -x` JSON is
   captured as a baseline, before the destructive burn-in, so that it can be
   compared against afterwards. Serial, model, health, power-on hours, and the
   defect/error counters are shown, plus SSD/SAS telemetry when the drive
   reports it: endurance used, temperature, SAS phy errors, corrected-error
   count, and background media scan status. 

   A drive that SMART already reports as *damaged*, such as a failed health
   check or a nonzero grown-defect/reallocated or uncorrected-error count, is
   rejected right here, so you don't have to wait days to find out it's busted.
   Wear/age signals (i.e. endurance used, high temperature) only produce
   *warnings* and do not indicate a rejection.
3. **Short SMART self-test.** `smartctl -t short` (~1–2 min). Again, this allows
   us to reject drives sooner if they fail the short self-test before running
   `badblocks`.
4. **User confirmation.** You must type the drive's serial number to proceed, as
   the next step will destroy any data on the drive.
5. **Surface pass.** `badblocks -b 8192 -wsv -t random` performs a full write and
   verify of every sector. Any bad block or I/O error here will result in the
   drive being rejected.  Skipped if `--no-write` is passed (see below).
6. **Long SMART self-test.** `smartctl -t long`. The drive runs this
   internally, so it continues even after this process exits.

#### Arguments

- `--dry-run`: run through the pre-flight checks and prints what a real run 
  would do, without writing anything or starting any self-test.
- `--no-write`: run a *non-destructive* qualification. This will run the SMART
  self-tests and telemetry, but skips the `badblocks(8)` surface pass, so no 
  existing data is destroyed (and no SSD write endurance is used). 

  This is a much more limited test than the destructive `badblocks(8)` pass.
  Writing to the disk is never exercised, and on a fresh SSD the self-test has
  little pre-existing content to scan. However, it may be used to re-qualify a
  device that already contains data.

### `burninate check`

```console
burninate check [--wait] [--interval DURATION] /dev/disk/by-id/<DRIVE>
```

Check if a burn-in started by `burninate start` has completed, and if it has,
display the result. 

### Arguments

- `--wait`: Continually poll silenly until the test has completed.
  Without `--wait`, an in-progress self-test exits immediately with status 4.
  With `--wait`, `burninate` polls silently every 15 minutes and only prints and
  saves the check result once the test has finished. Operational errors still
  print immediately.

- `--interval <duration>`: Override the polling interval for `--wait`.
  By default, `burninate check --wait` will poll every 15 minutes. Passing the
  `--interval` flag selects a different interval. It accepts a positive integer
  with an
optional seconds/minutes/hours suffix, such as `30s`, `15m`, or `1h`. A bare
number is interpreted as seconds.

### `burninate tmux`

```console
burninate tmux [--session NAME] [--interval DURATION] [--no-write] <DRIVES...>
```

Spawn a `tmux(1)` session wih one or more `burninate` processes.

Burn-in processes are long-running: `badblocks` is a foreground process, and
losing its terminal kills the surface pass. Thus, it's important to ensure that
each burn-in run is not attached directly to a user SSH session that might go
away if, say, a network connection is interrupted. The optional `tmux`
subcommand creates a root-owned `tmux(1)` session with vertically stacked,
evenly-sized panes, one pane per drive. Each pane runs 
`burninate start && burninate check --wait`,
and exited panes remain visible for review.

`tmux` is intentionally not a packaged runtime dependency for the Nix package,
unlike other dependencies that the core `burninate` command needs to run. If it
is not already on `PATH`, this subcommand fails.

```console
sudo burninate tmux \
  /dev/disk/by-id/wwn-0x5000... \
  /dev/disk/by-id/wwn-0x5001... \
  /dev/disk/by-id/wwn-0x5002...
```

The subcommand validates every device before creating the session, creates the
session, and attaches to it. Each pane initially waits for that drive's
serial-number confirmation. Users can move between panes with `Ctrl-b` followed
by `Up`/`Down`. 

If the user detaches from the session with `Ctrl-b d`, the jobs continue in the
`tmux` server. Reattach later with:

```console
sudo tmux attach-session -t burninate
```

Use `--session NAME` to choose another session name, `--interval 30m` to change
the quiet `check --wait` polling interval, or `--no-write` to pass that option
to every `start` job:

```console
sudo burninate tmux --session ssds --interval 30m --no-write \
  /dev/disk/by-id/wwn-0x5000... \
  /dev/disk/by-id/wwn-0x5001...
```

The chained `check --wait` is silent while the drive runs its long self-test, so
each pane keeps showing the last lines from `start` until the final PASS/FAIL
appears. Pane borders show the by-id basename, and `remain-on-exit` preserves
completed and failed jobs. With more drives than fit legibly in one terminal,
use separate sessions rather than shrinking panes to one or two lines.

### Exit codes

Exit status 3 indicates that a drive has failed the burn-in process. This allows
you to programmatically distinguish a failed drive from other issues such as a
device path that doesn't exist, a missing dependency, and so on.

| exit | meaning                                                               |
|------|-----------------------------------------------------------------------|
| 0    | PASS, or checks started successfully                                  |
| 1    | usage or operational error (not root, bad args, existing FS on drive) |
| 3    | REJECT: the drive failed burn-in; do not use it (reasons on stderr)   |
| 4    | RETRY: the long self-test is still running, run `check` again later   |


## Acceptance criteria

These checks are performed by `burninate start`, and failing them allows a drive
to be rejected prior to starting the long SMART self check:

1. the short SMART self-check passed prior to running `badblocks`,
2. the `badblocks` surface pass did not find any bad blocks.

A drive is considered to have passed a full burn-in if all of the following
conditions, checked by `burninate check`, are true:

1. the long/extended SMART self-test completed without error,
2. the SMART overall-health self-assessment reports PASSED;
3. the grown-defect or reallocated-sector count did not increase from the
   baseline captured prior to running the `badblocks` surface pass,
4. no uncorrectable errors detected after the surface pass.

On SAS SSDs the grown-defect list is a weak signal, since many SSDs reallocate
internally without populating it. There, the endurance indicator and the
corrected/uncorrected error counters are more important. 

Rising SAS phy errors and corrected (reread/rewrite) error counts between the
baseline and check are reported as warnings rather indicating that the drive
should be rejected. SAS phy errors usually indicate a problem with a cable or
backplane slot rather than the drive itself. Rising corrected errors indicate
early wear worth noting, but do not mean the drive has failed.

> [!NOTE]
> If a drive is considered to be "new" prior to burn-in, you may also want to
> manually spot-check its power-on hours, which are printed when capturing the
> baseline health statistics. If it was advertised as being new by a seller but
> has a large number of power-on hours or spin-up/down cycles, something fishy
> might be going on!

## SSDs and write endurance

`burninate` runs the same single write+verify surface pass on SSDs as on HDDs by
default, and this is a deliberate choice. One full-drive write costs roughly
0.02–0.06% of the rated endurance of a 1–3 DWPD enterprise SSD (rated for
thousands of full writes over its warranty), which is negligible for such
drives, and not even enough to move the drive's whole-percent "percentage used"
indicator. On consumer SSDs, and especially cheap ones, this may not be as true.

More importantly, however, on an SSD, the `badblocks` run is *not* a complete
test of the storage media. Since the flash translation layer remaps logical
blocks to arbitrary NAND, writing every LBA doesn't touch every NAND cell. An
immediate read-back exercises the write/data path rather than data retention.
The real media scan on an SSD is the drive's own long SMART self-test (which
burninate will also run). This reads the physical media with knowledge of the
layout. The write pass is kept because it's the only stage that exercises the
write and data paths and lays down known content for the self-test to scan.
Skipping it (with `--no-write`) is strictly weaker, even for SSDs. Reach for it
only when you cannot spend the write, such as re-qualifying a drive you must not
erase.

## State directory

By default, data generated by `burninate` is written to
`/var/lib/burninate/<serial>/`. This includes the pre-check `baseline.json`,
snapshots generated by `burninate check`, and the output from `badblocks`.

The directory root can be overridden by the `BURNINATE_STATE_ROOT` environment
variable.

## How the drive facts are read

Every drive fact comes from the  `smartctl -j` (JSON) capture per
invocation, extracted with `jq`. `serial`/`model`/`health`/`hours` are unified
top-level keys across ATA, SCSI, and NVMe; defect and error counters live in
transport-specific subtrees, so those filters try the SCSI keys and fall back to
the ATA attribute table keyed on the numeric attribute id (5 for reallocated
sectors; 187 + 198 for uncorrected errors) rather than the attribute *name*,
which varies between drives.

smartmontools does not publish its JSON as a stable schema — every dump carries
`"json_format_version":[1,0]` and `smartctl(8)` warns the format may change — so
the key paths are pinned against smartmontools 7.x and verified against real
ATA/SCSI/NVMe dumps (see `samples/` and `tests/`).

## Development

```console
nix flake check
```

runs three checks:

- `help` builds the Nix app (which, in turn, runs `shellcheck`) and executes
  `burninate --help`;
- `parsing` runs `tests/parsing.sh`, which tests the code for parsing
  `smartctl`'s JSON output. This tests the parsing helpers against actual
  `smartctl` output from an ATA (SATA) SSD, a SAS HDD, a SAS SSD, and an NVMe
  SSD, which live in `tests/samples/*.json.`
- `cli` runs `tests/cli.sh`, which tests command-line dispatch, interval
  parsing, exit statuses, and tmux pane-command quoting.

Both test scripts source `burninate.sh`. Its `main` function is run only when
invoked directly, so that sourcing the script will just define the various
functions we wish to test. `tests/common.sh` defines a small test harness for
these functions. To run the tests ouside Nix:

```console
bash tests/parsing.sh
bash tests/cli.sh
```
