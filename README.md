# chia-fill

Plot one Chia k32 at a time on a plotter, then **fully move** that plot to a remote harvester before starting the next one. Repeat until every configured destination drive is full.

`chia-fill` is a small bash wrapper around [madMAx `chia_plot`](https://github.com/madMAx43v3r/chia-plotter) and `rsync`. It is meant for a two-machine setup: fast temp disks on the plotter, final `.plot` files on the harvester.

## Why this exists

`chia_plot -d` is **local staging**, not the harvester. The real destination is another machine (`user@host:/mnt/hdd-NN`).

A k32 plot is about **102 GiB**. If you start the next plot before the previous file has finished transferring, staging fills up, temp disks get crowded, and a failed copy is easy to miss. chia-fill makes the contract explicit:

1. Create **one** plot into local staging.
2. `rsync` it to the harvester.
3. Confirm the remote file exists at the same size.
4. Remove the local copy.
5. Only then start the next plot.

If the move fails, the loop **stops immediately** and prints a red `JOB FAILED` banner. It will not keep plotting on top of a stuck transfer.

```
  plotter machine                         harvester
  ---------------                         ---------
  chia_plot -t / -2   (tmp SSD)
         |
         v
  chia_plot -d        local staging .plot
         |
         |  rsync --whole-file  (as *.xfer, then rename to .plot)
         v
  user@host:/mnt/hdd-01, /mnt/hdd-02, ...
```

## Requirements

On the **plotter**:

- bash, `ssh`, `rsync`, `flock` (util-linux)
- [madMAx `chia_plot`](https://github.com/madMAx43v3r/chia-plotter)
- SSH key login to the harvester (**no password prompt**; `BatchMode` is required)
- Enough staging disk for at least one finished k32 (~102 GiB)

On the **harvester**:

- SSH server
- The destination mount points already exist (for example `/mnt/hdd-01`)

## Quick start

```bash
git clone https://github.com/<you>/chia-fill.git
cd chia-fill
chmod +x chia-fill.sh
cp chia-fill.conf chia-fill.conf.local   # optional: keep a private copy
```

Edit `chia-fill.conf` (or pass flags) so the plotter path, temp disks, pool contract, farmer public key, and remote drives match your machines.

```bash
# See what the script will use
./chia-fill.sh --show-config

# One plot, then one move, then exit
./chia-fill.sh --once

# Fill every destination that still has at least 102 GiB free
./chia-fill.sh
```

Confirm SSH works first:

```bash
ssh steve@jango 'df -h /mnt/hdd-01'
```

## Configuration

Defaults live in `chia-fill.conf` next to the script. **CLI flags override the config.**

| Setting | Meaning |
| --- | --- |
| `PLOTTER` | Path to the `chia_plot` binary |
| `TMP_DIR` | `chia_plot -t` working temp |
| `TMP2_DIR` | `chia_plot -2` second temp |
| `STAGING_DIR` | `chia_plot -d` — local directory where the finished `.plot` lands |
| `POOL_CONTRACT` | Pool contract address (`-c`) |
| `FARMER_KEY` | Farmer **public** key (`-f`) |
| `THREADS` | Plotter thread count (`-r`) |
| `PLOT_LOG` | Tee'd plotter output |
| `DEST_USER` / `DEST_HOST` | Harvester SSH target |
| `DEST_PATHS` | Remote drives, in preference order |
| `BWLIMIT` | `rsync --bwlimit` (for example `800m`) |
| `MIN_FREE_GB` | Do not start a plot unless a dest has at least this much free (default `102`) |
| `PLOTTER_RETRIES` | Plotter failures to retry before aborting |
| `LOCK_FILE` | Prevents two chia-fill runs on the same plotter |
| `FILL_LOG` | Optional extra copy of chia-fill log lines |

`PLOT_COUNT` is forced to `1` at runtime. Sequential fill only works if each cycle produces a single plot.

Do not commit a config that contains machine-specific paths you want private. The sample `chia-fill.conf` in this repo is a template (`YOUR-POOL-CONTRACT-ADDRESS`, `YOUR-FARMER-KEY`).

## Command-line options

```text
-c, --config FILE       Config file (default: ./chia-fill.conf)
    --plotter PATH      chia_plot binary
-t, --tmp PATH          chia_plot -t temp directory
-2, --tmp2 PATH         chia_plot -2 second temp directory
-d, --staging PATH      Local staging directory (chia_plot -d)
-u, --user USER         Remote user
-H, --host HOST         Remote host
-p, --path PATH         Remote destination path (repeatable; replaces the config list)
-b, --bwlimit LIMIT     rsync bandwidth limit (e.g. 800m)
-r, --threads N         Plotter thread count
-m, --min-free-gb N     Minimum free GiB required on a destination
-n, --max-plots N       Stop after N successful plot+move cycles (0 = until full)
    --once              Same as --max-plots 1
    --drain-only        Move leftover staging plots; do not create new ones
    --dry-run           Print actions without plotting or transferring
    --show-config       Print effective settings and exit
-l, --log FILE          Also append chia-fill messages to this file
-h, --help              Show help
```

Examples:

```bash
# Override host and a couple of drives for this run
./chia-fill.sh -H jango -p /mnt/hdd-05 -p /mnt/hdd-06 --bwlimit 400m

# Move whatever is already sitting in staging, then stop
./chia-fill.sh --drain-only

# Simulate one cycle (SSH is still used to inspect free space)
./chia-fill.sh --dry-run
```

## How a move works

For each finished `.plot` in staging, chia-fill:

1. Picks the first remote path in `DEST_PATHS` that exists and has at least `MIN_FREE_GB` free.
2. `rsync --whole-file` to `filename.plot.xfer` on the harvester (so a harvester scanning `*.plot` will not pick up a partial file).
3. Renames `.xfer` → `.plot` on the remote side.
4. Compares local and remote sizes.
5. Deletes the local file only after that check succeeds.

If a same-size copy is already on the remote, the local file is removed and the move is treated as done. Leftover plots in staging from a crash are drained **before** the next plot starts.

SSH connections use a ControlMaster socket so the many `df` / `stat` checks do not open a new TCP session every time.

## When it stops

| Situation | Result |
| --- | --- |
| Every reachable dest is below `MIN_FREE_GB` | Success — “all destinations are full” |
| rsync, remote rename, or size check fails | **Job failed** — red banner, exit 1, local plot kept |
| Plotter exits 0 but no `.plot` appears in staging | **Job failed** |
| Plotter fails more than `PLOTTER_RETRIES` times | **Job failed** |
| SSH to the harvester fails | **Job failed** |
| `--max-plots` / `--once` reached | Success |
| `--drain-only` finished | Success |

A failed move leaves the local `.plot` in staging so you can fix the harvester and re-run `./chia-fill.sh --drain-only`.

Only one chia-fill process can run at a time (`LOCK_FILE` + `flock`).

## Tips

- Run it in `tmux` or `screen`. A k32 plus a 102 GiB rsync takes a while.
- `--bwlimit` keeps the LAN usable while plots copy. `800m` is 800 Mbit/s in rsync units, not megabytes.
- `MIN_FREE_GB` should stay at or above one k32 (102) so a drive is never chosen when the plot cannot fit.
- Destination order in `DEST_PATHS` is the fill order. Put the drive you want filled first at the top of the list.
- The farmer key in `chia_plot -f` is the **public** farmer key from `chia keys show`, not a private mnemonic.

## License

Use and modify freely. No warranty: plots are large and slow to rebuild, so test with `--show-config`, `--dry-run`, and `--once` before an unattended fill.
