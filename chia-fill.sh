#!/usr/bin/env bash
# chia-fill.sh
# Plot one k32 at a time on this machine, then rsync it to a remote harvester
# before starting the next plot. Stops when every configured destination path
# is below MIN_FREE_GB. Aborts with a red banner if a move fails.
#
# chia_plot -d is LOCAL staging only. The real destination is DEST_USER@DEST_HOST.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/chia-fill.conf"

# --- in-script defaults (chia-fill.conf overrides these; CLI overrides both) ---
PLOTTER="${HOME}/madmax/chia-plotter/build/chia_plot"
TMP_DIR="/mnt/ssd-ta/"
TMP2_DIR="/mnt/ssd-ta/"
STAGING_DIR="/mnt/ssd-tb"
PLOT_COUNT=1
POOL_CONTRACT=""
FARMER_KEY=""
THREADS=20
PLOT_LOG="${HOME}/chialogs/chia-fill-plotter.log"
DEST_USER="steve"
DEST_HOST="jango"
DEST_PATHS=()
BWLIMIT="800m"
MIN_FREE_GB=102
PLOTTER_RETRIES=2
LOCK_FILE="/tmp/chia-fill.lock"
FILL_LOG=""

MAX_PLOTS=0          # 0 = keep going until destinations are full
DRAIN_ONLY=0
DRY_RUN=0
SHOW_CONFIG=0
CLI_DEST_PATHS=()

SSH_CONTROL_PATH=""
PLOTS_CREATED=0
PLOTS_MOVED=0

usage() {
    cat <<'EOF'
Usage: chia-fill.sh [OPTIONS]

Create one Chia k32 plot, fully move it to a remote harvester, then repeat.
The loop stops when every remote destination is below --min-free-gb.
If a move fails, the loop aborts immediately with a red banner.

"Destination" here is the remote harvester, not chia_plot -d.
  chia_plot -t / -2   working temp on this machine
  chia_plot -d        local staging directory (finished .plot lands here)
  --host / --path     real destination: user@host:/path on the harvester

Options:
  -c, --config FILE       Config file (default: <script-dir>/chia-fill.conf)
      --plotter PATH      chia_plot binary
  -t, --tmp PATH          chia_plot -t temp directory
  -2, --tmp2 PATH         chia_plot -2 second temp directory
  -d, --staging PATH      Local staging directory (chia_plot -d)
  -u, --user USER         Remote user
  -H, --host HOST         Remote host
  -p, --path PATH         Remote destination path (repeatable; replaces config list)
  -b, --bwlimit LIMIT     rsync bandwidth limit (e.g. 800m)
  -r, --threads N         Plotter thread count
  -m, --min-free-gb N     Minimum free GiB required on a destination
  -n, --max-plots N       Stop after N successful plot+move cycles (0 = until full)
      --once              Same as --max-plots 1
      --drain-only        Move leftover staging plots only; do not create new ones
      --dry-run           Print actions without plotting or transferring
      --show-config       Print effective settings and exit
  -l, --log FILE          Also append chia-fill messages to this file
  -h, --help              Show this help

Examples:
  chia-fill.sh
  chia-fill.sh --once
  chia-fill.sh -H jango -p /mnt/hdd-05 -p /mnt/hdd-06 --bwlimit 400m
  chia-fill.sh --drain-only
EOF
}

init_color() {
    if [[ -t 1 ]]; then
        RED=$'\033[1;31m'
        GREEN=$'\033[1;32m'
        YELLOW=$'\033[1;33m'
        BOLD=$'\033[1m'
        RESET=$'\033[0m'
    else
        RED="" GREEN="" YELLOW="" BOLD="" RESET=""
    fi
}

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line"
    if [[ -n "${FILL_LOG}" ]]; then
        echo "$line" >> "${FILL_LOG}"
    fi
}

die() {
    log "ERROR: $*"
    exit 1
}

fail_job() {
    local reason="$*"
    echo
    printf '%s\n' "${RED}${BOLD}"
    cat <<'BANNER'
************************************************************************
**                                                                    **
**   JOB FAILED  —  loop aborted                                      **
**                                                                    **
************************************************************************
BANNER
    printf '%s\n' "${RESET}"
    echo "  Reason: ${reason}"
    echo
    log "JOB FAILED: ${reason}"
    exit 1
}

require_arg() {
    local opt="$1"
    local val="${2:-}"
    [[ -n "${val}" ]] || die "Option ${opt} requires an argument"
}

# --- argument parsing -------------------------------------------------------

for _arg in "$@"; do
    case "${_arg}" in
        -h|--help) usage; exit 0 ;;
    esac
done

_pre_args=("$@")
for ((i = 0; i < ${#_pre_args[@]}; i++)); do
    case "${_pre_args[$i]}" in
        -c|--config)
            CONFIG_FILE="${_pre_args[$((i + 1))]:-}"
            [[ -n "${CONFIG_FILE}" ]] || die "--config requires a file argument"
            ;;
    esac
done

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
else
    if [[ "${CONFIG_FILE}" != "${SCRIPT_DIR}/chia-fill.conf" ]]; then
        die "config file not found: ${CONFIG_FILE}"
    fi
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            require_arg "$1" "${2:-}"
            shift 2
            ;;
        --plotter)
            require_arg "$1" "${2:-}"
            PLOTTER="$2"
            shift 2
            ;;
        -t|--tmp)
            require_arg "$1" "${2:-}"
            TMP_DIR="$2"
            shift 2
            ;;
        -2|--tmp2)
            require_arg "$1" "${2:-}"
            TMP2_DIR="$2"
            shift 2
            ;;
        -d|--staging)
            require_arg "$1" "${2:-}"
            STAGING_DIR="$2"
            shift 2
            ;;
        -u|--user)
            require_arg "$1" "${2:-}"
            DEST_USER="$2"
            shift 2
            ;;
        -H|--host)
            require_arg "$1" "${2:-}"
            DEST_HOST="$2"
            shift 2
            ;;
        -p|--path)
            require_arg "$1" "${2:-}"
            CLI_DEST_PATHS+=("$2")
            shift 2
            ;;
        -b|--bwlimit)
            require_arg "$1" "${2:-}"
            BWLIMIT="$2"
            shift 2
            ;;
        -r|--threads)
            require_arg "$1" "${2:-}"
            THREADS="$2"
            shift 2
            ;;
        -m|--min-free-gb)
            require_arg "$1" "${2:-}"
            MIN_FREE_GB="$2"
            shift 2
            ;;
        -n|--max-plots)
            require_arg "$1" "${2:-}"
            MAX_PLOTS="$2"
            shift 2
            ;;
        --once)
            MAX_PLOTS=1
            shift
            ;;
        --drain-only)
            DRAIN_ONLY=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --show-config)
            SHOW_CONFIG=1
            shift
            ;;
        -l|--log)
            require_arg "$1" "${2:-}"
            FILL_LOG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1  (try --help)"
            ;;
    esac
done

if (( ${#CLI_DEST_PATHS[@]} > 0 )); then
    DEST_PATHS=("${CLI_DEST_PATHS[@]}")
fi

init_color

# --- helpers ----------------------------------------------------------------

gib() {
    local bytes="${1:-0}"
    [[ "${bytes}" =~ ^[0-9]+$ ]] || { echo "?"; return; }
    echo "$((bytes / 1024 / 1024 / 1024))"
}

short_name() {
    local n="$1"
    if (( ${#n} > 48 )); then
        echo "${n:0:35}...${n: -8}"
    else
        echo "$n"
    fi
}

elapsed_hms() {
    local s="$1"
    printf '%dm %ds' "$((s / 60))" "$((s % 60))"
}

print_config() {
    cat <<EOF
chia-fill effective settings
  config:       ${CONFIG_FILE}
  plotter:      ${PLOTTER}
  tmp (-t):     ${TMP_DIR}
  tmp2 (-2):    ${TMP2_DIR}
  staging (-d): ${STAGING_DIR}
  threads:      ${THREADS}
  plot log:     ${PLOT_LOG}
  fill log:     ${FILL_LOG:-"(stdout only)"}
  remote:       ${DEST_USER}@${DEST_HOST}
  dest paths:   ${DEST_PATHS[*]}
  bwlimit:      ${BWLIMIT}
  min free:     ${MIN_FREE_GB} GiB
  max plots:    ${MAX_PLOTS} (0 = until destinations are full)
  drain only:   ${DRAIN_ONLY}
  dry run:      ${DRY_RUN}
EOF
}

ssh_dest() {
    ssh -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o ControlMaster=auto \
        -o ControlPath="${SSH_CONTROL_PATH}" \
        -o ControlPersist=600 \
        "${DEST_USER}@${DEST_HOST}" "$@"
}

RSYNC_RSH=""
init_ssh() {
    SSH_CONTROL_PATH="/tmp/chia-fill-ssh-${DEST_USER}-${DEST_HOST}.sock"
    RSYNC_RSH="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ControlMaster=auto -o ControlPath=${SSH_CONTROL_PATH} -o ControlPersist=600"
}

remote_avail_bytes() {
    local path="$1"
    ssh_dest "df -B1 --output=avail '${path}' 2>/dev/null | tail -n1" | tr -d '[:space:]'
}

# Sets CHOSEN_DEST. Logs to stdout. Does not mix the chosen path into command substitution.
# Returns 0 if a dest with enough free space was found, 1 if every reachable dest is full.
# Connection / path errors abort the job instead of looking like "all disks are full".
CHOSEN_DEST=""
pick_destination() {
    local path avail rc
    local saw_reachable=0
    CHOSEN_DEST=""
    for path in "${DEST_PATHS[@]}"; do
        ssh_dest "[ -d '${path}' ]"
        rc=$?
        if (( rc == 255 )); then
            fail_job "SSH connection failed while checking ${DEST_HOST}:${path}"
        fi
        if (( rc != 0 )); then
            log "SKIP ${DEST_HOST}:${path} (path does not exist)"
            continue
        fi

        avail="$(remote_avail_bytes "${path}")"
        if ! [[ "${avail}" =~ ^[0-9]+$ ]]; then
            log "SKIP ${DEST_HOST}:${path} (could not read free space)"
            continue
        fi

        saw_reachable=1
        if (( avail >= MIN_FREE_BYTES )); then
            CHOSEN_DEST="${path}"
            return 0
        fi

        log "FULL  ${DEST_HOST}:${path} ($(gib "${avail}") GiB free)"
    done

    if (( saw_reachable == 0 )); then
        fail_job "No usable destination path on ${DEST_HOST} (missing or unreadable)"
    fi
    return 1
}

staging_plot_list() {
    find "${STAGING_DIR}" -maxdepth 1 -name '*.plot' -type f 2>/dev/null | sort
}

staging_plot_count() {
    staging_plot_list | wc -l | tr -d '[:space:]'
}

# Transfer one finished .plot. Source is removed only after the remote file
# exists at the same size under its final name (not *.xfer).
move_one_plot() {
    local plotfile="$1"
    local dest_path="$2"
    local filename short local_size remote_size remote_tmp remote_final
    local start_seconds end_seconds

    filename="$(basename "${plotfile}")"
    short="$(short_name "${filename}")"
    local_size="$(stat -c %s "${plotfile}" 2>/dev/null || true)"
    [[ "${local_size}" =~ ^[0-9]+$ ]] || return 1

    remote_tmp="${dest_path}/${filename}.xfer"
    remote_final="${dest_path}/${filename}"

    if (( DRY_RUN )); then
        log "DRY-RUN would move ${short} ($(gib "${local_size}") GiB) -> ${DEST_USER}@${DEST_HOST}:${dest_path}/"
        return 0
    fi

    remote_size="$(ssh_dest "stat -c %s '${remote_final}' 2>/dev/null" | tr -d '[:space:]' || true)"
    if [[ "${remote_size}" == "${local_size}" ]]; then
        log "Remote already has ${short} at the same size; removing local copy"
        rm -f "${plotfile}"
        return 0
    fi

    log "Moving ${short} ($(gib "${local_size}") GiB) -> ${DEST_USER}@${DEST_HOST}:${dest_path}/"
    start_seconds="$(date +%s)"

    if ! rsync -a --whole-file --progress --bwlimit="${BWLIMIT}" \
            -e "${RSYNC_RSH}" \
            "${plotfile}" "${DEST_USER}@${DEST_HOST}:${remote_tmp}"; then
        ssh_dest "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true
        log "rsync failed for ${filename}"
        return 1
    fi

    if ! ssh_dest "mv -f '${remote_tmp}' '${remote_final}'"; then
        log "Remote rename failed for ${filename}"
        return 1
    fi

    remote_size="$(ssh_dest "stat -c %s '${remote_final}' 2>/dev/null" | tr -d '[:space:]')"
    if [[ "${remote_size}" != "${local_size}" ]]; then
        log "Size mismatch for ${filename}: local=${local_size} remote=${remote_size:-missing}"
        return 1
    fi

    rm -f "${plotfile}"
    end_seconds="$(date +%s)"
    log "MOVED  ${short}  [SUCCESS] $(elapsed_hms "$((end_seconds - start_seconds))")"
    PLOTS_MOVED=$((PLOTS_MOVED + 1))
    return 0
}

# Move every leftover .plot in staging. Re-picks a destination for each file.
drain_staging() {
    local plot dest leftover
    leftover="$(staging_plot_count)"
    if (( leftover == 0 )); then
        return 0
    fi

    log "Found ${leftover} plot(s) in staging; moving those first"
    while IFS= read -r plot; do
        [[ -n "${plot}" ]] || continue
        [[ -f "${plot}" ]] || continue
        if ! pick_destination; then
            fail_job "Leftover plot $(basename "${plot}") is in ${STAGING_DIR} but no destination has ${MIN_FREE_GB} GiB free"
        fi
        dest="${CHOSEN_DEST}"
        log "Using ${DEST_HOST}:${dest} ($(gib "$(remote_avail_bytes "${dest}")") GiB free)"
        if ! move_one_plot "${plot}" "${dest}"; then
            fail_job "Failed to move $(basename "${plot}") to ${DEST_USER}@${DEST_HOST}:${dest}"
        fi
    done < <(staging_plot_list)
}

run_plotter() {
    local attempt="$1"
    log "Starting plotter (attempt ${attempt}) -t ${TMP_DIR} -2 ${TMP2_DIR} -d ${STAGING_DIR}"
    if (( DRY_RUN )); then
        log "DRY-RUN would invoke: ${PLOTTER} -t ${TMP_DIR} -2 ${TMP2_DIR} -d ${STAGING_DIR}/ -n ${PLOT_COUNT} -c <pool> -f <farmer> -r ${THREADS}"
        return 0
    fi

    "${PLOTTER}" \
        -t "${TMP_DIR}" \
        -2 "${TMP2_DIR}" \
        -d "${STAGING_DIR}/" \
        -n "${PLOT_COUNT}" \
        -c "${POOL_CONTRACT}" \
        -f "${FARMER_KEY}" \
        -r "${THREADS}" \
        2>&1 | tee -a "${PLOT_LOG}"

    return "${PIPESTATUS[0]}"
}

cleanup() {
    if [[ -n "${SSH_CONTROL_PATH}" ]]; then
        ssh -o ControlPath="${SSH_CONTROL_PATH}" -O exit "${DEST_USER}@${DEST_HOST}" >/dev/null 2>&1 || true
    fi
}

on_interrupt() {
    echo
    log "Interrupted. Plotter/rsync may still be shutting down."
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# --- validation / startup ---------------------------------------------------

if (( SHOW_CONFIG )); then
    print_config
    exit 0
fi

[[ "${MIN_FREE_GB}" =~ ^[0-9]+$ ]] || die "--min-free-gb must be an integer"
[[ "${THREADS}" =~ ^[0-9]+$ ]] || die "--threads must be an integer"
[[ "${MAX_PLOTS}" =~ ^[0-9]+$ ]] || die "--max-plots must be an integer"
[[ "${PLOTTER_RETRIES}" =~ ^[0-9]+$ ]] || die "PLOTTER_RETRIES must be an integer"
(( ${#DEST_PATHS[@]} > 0 )) || die "No destination paths configured (set DEST_PATHS in config or pass -p)"

# Sequential fill only works if chia_plot writes exactly one file per cycle.
PLOT_COUNT=1

MIN_FREE_BYTES=$((MIN_FREE_GB * 1024 * 1024 * 1024))

command -v ssh >/dev/null || die "ssh not found"
command -v rsync >/dev/null || die "rsync not found"
command -v flock >/dev/null || die "flock not found"
if (( DRAIN_ONLY == 0 )); then
    [[ -x "${PLOTTER}" ]] || die "plotter not executable: ${PLOTTER}"
    [[ -d "${TMP_DIR}" ]] || die "tmp dir missing: ${TMP_DIR}"
    [[ -d "${TMP2_DIR}" ]] || die "tmp2 dir missing: ${TMP2_DIR}"
    [[ -n "${POOL_CONTRACT}" ]] || die "POOL_CONTRACT is empty (set it in ${CONFIG_FILE})"
    [[ -n "${FARMER_KEY}" ]] || die "FARMER_KEY is empty (set it in ${CONFIG_FILE})"
fi

mkdir -p "${STAGING_DIR}" "$(dirname "${PLOT_LOG}")"
if [[ -n "${FILL_LOG}" ]]; then
    mkdir -p "$(dirname "${FILL_LOG}")"
fi

if (( DRY_RUN && MAX_PLOTS == 0 )); then
    MAX_PLOTS=1
    log "Dry-run defaulting to one simulated plot+move cycle (pass -n to simulate more)"
fi

if (( DRY_RUN == 0 )); then
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        die "another chia-fill.sh is already running (lock: ${LOCK_FILE})"
    fi
fi

init_ssh

log "=== chia-fill started ==="
print_config
echo "-------------------------------------------------------------"

if ! ssh_dest "true"; then
    fail_job "Cannot ssh to ${DEST_USER}@${DEST_HOST} (need key-based BatchMode login)"
fi

drain_staging

if (( DRAIN_ONLY )); then
    log "Drain-only complete. Plots moved: ${PLOTS_MOVED}"
    log "=== chia-fill finished ==="
    exit 0
fi

# --- main loop: plot one, move it, repeat -----------------------------------

plotter_failures=0

while true; do
    leftover="$(staging_plot_count)"
    if (( leftover > 0 )); then
        drain_staging
    fi

    if (( MAX_PLOTS > 0 && PLOTS_CREATED >= MAX_PLOTS )); then
        log "Reached --max-plots ${MAX_PLOTS}. Stopping."
        break
    fi

    if ! pick_destination; then
        log "${GREEN}All destinations are below ${MIN_FREE_GB} GiB free. Done.${RESET}"
        break
    fi

    dest_path="${CHOSEN_DEST}"
    avail="$(remote_avail_bytes "${dest_path}")"
    log "Will plot into staging, then move to ${DEST_HOST}:${dest_path} ($(gib "${avail}") GiB free)"

    if ! run_plotter "$((plotter_failures + 1))"; then
        plotter_failures=$((plotter_failures + 1))
        if (( plotter_failures > PLOTTER_RETRIES )); then
            fail_job "Plotter failed ${plotter_failures} time(s) (limit ${PLOTTER_RETRIES} retries)"
        fi
        log "${YELLOW}Plotter failed (try ${plotter_failures}/${PLOTTER_RETRIES}). Retrying.${RESET}"
        continue
    fi
    plotter_failures=0
    PLOTS_CREATED=$((PLOTS_CREATED + 1))

    leftover="$(staging_plot_count)"
    if (( leftover == 0 && DRY_RUN == 0 )); then
        fail_job "Plotter exited successfully but no .plot file appeared in ${STAGING_DIR}"
    fi

    # Re-pick after plotting: another writer may have filled the original dest.
    drain_staging
done

echo "-------------------------------------------------------------"
log "${GREEN}=== chia-fill finished ===${RESET}"
log "Plots created this run: ${PLOTS_CREATED}"
log "Plots moved this run:   ${PLOTS_MOVED}"
