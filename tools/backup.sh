#!/usr/bin/env bash
# Backup + clean -- copy a phone's files to a big disk, then free the phone.
#
#   backup  Mirror internal storage (/storage/emulated/0) into <dest>/<device>/ over adb.
#           Incremental: a file already on the disk at the same size is skipped, so an
#           interrupted run is resumed by running it again.
#   clean   Delete files from the phone, but ONLY those whose backup copy matches by size
#           AND md5. Anything not backed up, or that differs, stays on the phone and is
#           listed. Defaults to the media folders, not the whole storage.
#
# Why adb and not MTP (plugging in and dragging folders): MTP stalls and silently drops
# files on large trees, cannot resume, and gives no way to prove a copy before deleting.
#
# Not covered, because it is not in shared storage: SMS/call log, contacts, app data and
# app settings. Those need the phone's own backup (Google/Samsung) or an app like
# SMS Backup & Restore.

if [[ -z "${SUITE_DIR:-}" ]]; then
    SUITE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fi

BACKUP_ROOT="/storage/emulated/0"
# Files per `adb pull` call. One call per file costs a round trip each, which is most of
# the runtime on a tree of small photos; one call per directory can overrun ARG_MAX.
BACKUP_BATCH="${BACKUP_BATCH:-200}"
# What `clean` touches when no --path is given: user media, never app state.
CLEAN_DEFAULT_PATHS=(DCIM Pictures Movies Download Documents Recordings Music)
DEVICE_TMP="/data/local/tmp/android-suite-clean.lst"

# backup_quote <s> -- single-quote for the device shell.
backup_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# backup_device_dir <dest> -- <dest>/<short device name>, e.g. /mnt/tb/android/zfold5.
backup_device_dir() {
    local model
    model=$(adb_cmd shell getprop ro.product.model | tr -d '\r')
    printf '%s/%s\n' "${1%/}" "$(device_short_name "$model")"
}

# backup_list_device <path>... -- "<size> <relpath>" for every file under the given
# paths (relative to BACKUP_ROOT). Android/data and Android/obb are app-private and get
# recreated by the apps; .thumbnails is a regenerated cache.
backup_list_device() {
    local p q=""
    for p in "$@"; do q+=" $(backup_quote "$p")"; done
    adb_cmd shell "cd $BACKUP_ROOT && find$q \\( -path '*Android/data' -o -path '*Android/obb' -o -name .thumbnails \\) -prune -o -type f -exec stat -c '%s %n' {} + 2>/dev/null" |
        tr -d '\r' | sed 's| \./| |'
}

# backup_list_local <dir> -- "<size> <relpath>" for every file already on the disk.
backup_list_local() {
    [[ -d "$1" ]] || return 0
    find "$1" -type f -printf '%s %P\n'
}

# backup_missing <device-list> <local-list> -- device rows with no same-size local copy.
# (`FILENAME == ARGV[1]`, not `NR == FNR`: with an empty first file NR == FNR stays true
# through the second one, and an empty backup dir would read as "everything is backed up".)
backup_missing() {
    awk 'FILENAME == ARGV[1] { i = index($0, " "); have[substr($0, i + 1)] = substr($0, 1, i - 1); next }
         { i = index($0, " "); p = substr($0, i + 1); if (have[p] != substr($0, 1, i - 1)) print }' "$2" "$1"
}

# backup_workdir -- a scratch dir removed when the script exits. Global, not local: an EXIT
# trap runs after every function has returned, where a local is unbound under `set -u`.
# Call it bare, never as $(...): the trap would fire as that subshell exits.
backup_workdir() {
    BACKUP_WORK=$(mktemp -d)
    trap 'rm -rf "$BACKUP_WORK"' EXIT
}

backup_human() { numfmt --to=iec --suffix=B "${1:-0}"; }

backup_sum() { awk '{ s += $1 } END { print s + 0 }' "$1"; }

backup_require_device() {
    local serial
    serial=$(get_device_serial) || return 1
    DEVICE_SERIAL="$serial"
    export DEVICE_SERIAL
}

cmd_backup() {
    check_adb || return 1
    [[ -n "${BACKUP_DEST:-}" ]] || { log_error "Where to? Pass --to <dir> (e.g. the mounted backup drive)"; return 1; }
    [[ -d "$BACKUP_DEST" ]] || { log_error "Not a directory (is the drive mounted?): $BACKUP_DEST"; return 1; }
    backup_require_device || return 1

    local dest work paths=("${BACKUP_PATHS[@]}")
    [[ ${#paths[@]} -gt 0 ]] || paths=(.)
    dest=$(backup_device_dir "$BACKUP_DEST")
    backup_workdir; work=$BACKUP_WORK

    log_section "Backup: $DEVICE_SERIAL -> $dest"
    log_info "Listing files on the phone (${paths[*]})..."
    backup_list_device "${paths[@]}" > "$work/device"
    backup_list_local "$dest" > "$work/local"
    backup_missing "$work/device" "$work/local" | LC_ALL=C sort -k2 > "$work/missing"

    local total todo need avail
    total=$(wc -l < "$work/device")
    todo=$(wc -l < "$work/missing")
    need=$(backup_sum "$work/missing")
    log_info "On phone: $total files, $(backup_human "$(backup_sum "$work/device")")"
    log_info "Already backed up: $((total - todo)) files"
    log_info "To copy: $todo files, $(backup_human "$need")"
    [[ "$todo" -gt 0 ]] || { log_success "Nothing to copy, backup is current"; return 0; }

    mkdir -p "$dest"
    avail=$(df --output=avail -B1 "$dest" | tail -1)
    if [[ "$need" -gt "$avail" ]]; then
        log_error "Not enough space: need $(backup_human "$need"), $(backup_human "$avail") free on $dest"
        return 1
    fi
    if is_dry_run; then
        log_info "[DRY RUN] first files that would be copied:"
        head -20 "$work/missing" | cut -d' ' -f2- | sed 's/^/  /' >&2
        return 0
    fi

    # Pull in batches that share a directory: `adb pull a b c dir/` flattens into dir/.
    local line rel dir batch=() batch_dir="" done_n=0
    flush() {
        [[ ${#batch[@]} -gt 0 ]] || return 0
        mkdir -p "$dest/$batch_dir"
        adb_cmd pull -a "${batch[@]}" "$dest/$batch_dir/" >/dev/null 2>>"$work/errors" ||
            log_warning "adb pull reported errors in $batch_dir (verified below)"
        done_n=$((done_n + ${#batch[@]}))
        log_info "[$done_n/$todo] $batch_dir"
        batch=()
    }
    while IFS= read -r line; do
        rel=${line#* }
        dir=$(dirname "$rel")
        if [[ "$dir" != "$batch_dir" || ${#batch[@]} -ge $BACKUP_BATCH ]]; then
            flush
            batch_dir=$dir
        fi
        batch+=("$BACKUP_ROOT/$rel")
    done < "$work/missing"
    flush

    # Verify by re-reading the disk, not by trusting adb's exit status.
    backup_list_local "$dest" > "$work/local"
    backup_missing "$work/missing" "$work/local" > "$work/failed"
    local failed
    failed=$(wc -l < "$work/failed")
    if [[ "$failed" -gt 0 ]]; then
        cp "$work/failed" "$dest/.backup-failed.txt"
        log_error "$failed files did not copy; list saved to $dest/.backup-failed.txt"
        [[ -s "$work/errors" ]] && tail -5 "$work/errors" >&2
        log_info "Run the same command again to retry just those."
        return 1
    fi
    rm -f "$dest/.backup-failed.txt"
    log_success "Backed up $todo files ($(backup_human "$need")) to $dest"
    log_info "Next: free the phone with  provision.sh clean --to $BACKUP_DEST --dry-run"
}

cmd_clean() {
    check_adb || return 1
    [[ -n "${BACKUP_DEST:-}" ]] || { log_error "Pass --to <dir>, the same one you backed up to"; return 1; }
    backup_require_device || return 1

    local dest work paths=("${BACKUP_PATHS[@]}")
    [[ ${#paths[@]} -gt 0 ]] || paths=("${CLEAN_DEFAULT_PATHS[@]}")
    dest=$(backup_device_dir "$BACKUP_DEST")
    [[ -d "$dest" ]] || { log_error "No backup for this phone at $dest; run backup first"; return 1; }
    backup_workdir; work=$BACKUP_WORK

    log_section "Clean: $DEVICE_SERIAL (backup at $dest)"
    log_info "Checking ${paths[*]}..."
    # Only paths that exist, so a phone without e.g. Recordings is not an error.
    local p existing=()
    for p in "${paths[@]}"; do
        adb_cmd shell "[ -e $BACKUP_ROOT/$(backup_quote "$p") ]" && existing+=("$p")
    done
    [[ ${#existing[@]} -gt 0 ]] || { log_info "None of those folders exist on the phone"; return 0; }

    backup_list_device "${existing[@]}" > "$work/device"
    backup_list_local "$dest" > "$work/local"
    backup_missing "$work/device" "$work/local" > "$work/unsafe"
    # Size-matched candidates, then hash both sides; only identical files may go.
    awk 'FILENAME == ARGV[1] { skip[$0] = 1; next } !skip[$0]' "$work/unsafe" "$work/device" |
        cut -d' ' -f2- > "$work/candidates"
    log_info "$(wc -l < "$work/candidates") files have a same-size backup; comparing checksums..."

    tr '\n' '\0' < "$work/candidates" > "$work/candidates.0"
    adb_cmd push "$work/candidates.0" "$DEVICE_TMP" >/dev/null
    adb_cmd shell "cd $BACKUP_ROOT && xargs -0 md5sum < $DEVICE_TMP 2>/dev/null; rm -f $DEVICE_TMP" |
        tr -d '\r' > "$work/md5.device"
    (cd "$dest" && xargs -0 md5sum -- < "$work/candidates.0" 2>/dev/null) > "$work/md5.local"
    awk 'FILENAME == ARGV[1] { h[substr($0, 35)] = substr($0, 1, 32); next }
         { p = substr($0, 35); if (h[p] == substr($0, 1, 32)) print p }' \
        "$work/md5.local" "$work/md5.device" > "$work/delete"

    local n_del n_keep bytes
    n_del=$(wc -l < "$work/delete")
    n_keep=$(($(wc -l < "$work/device") - n_del))
    bytes=$(awk 'FILENAME == ARGV[1] { ok[$0] = 1; next } { i = index($0, " "); if (ok[substr($0, i + 1)]) s += substr($0, 1, i - 1) } END { print s + 0 }' \
        "$work/delete" "$work/device")

    if [[ "$n_keep" -gt 0 ]]; then
        log_warning "$n_keep files are NOT in the backup (or differ) and will be kept, e.g.:"
        awk 'FILENAME == ARGV[1] { ok[$0] = 1; next } { i = index($0, " "); p = substr($0, i + 1); if (!ok[p]) print "  " p }' \
            "$work/delete" "$work/device" | head -10 >&2
        log_info "Run backup again to copy the missing ones. A file that differs at the same size"
        log_info "means the disk copy is bad: delete it from $dest and run backup again."
    fi
    [[ "$n_del" -gt 0 ]] || { log_info "Nothing verified to delete"; return 0; }
    log_info "Verified identical in backup: $n_del files, $(backup_human "$bytes") to free"

    if is_dry_run; then
        log_info "[DRY RUN] nothing deleted"
        return 0
    fi
    confirm "Delete these $n_del files from the phone?" || { log_info "Aborted, nothing deleted"; return 0; }

    tr '\n' '\0' < "$work/delete" > "$work/delete.0"
    adb_cmd push "$work/delete.0" "$DEVICE_TMP" >/dev/null
    adb_cmd shell "cd $BACKUP_ROOT && xargs -0 rm -f -- < $DEVICE_TMP; rm -f $DEVICE_TMP"
    log_success "Deleted $n_del files, freed about $(backup_human "$bytes")"
    log_info "Reboot the phone so Gallery and Files drop the deleted items."
}
