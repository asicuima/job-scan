#!/bin/bash
# Daily unattended job scan: fetch → diff → dedup → gates → merge → render,
# then (if enabled) LLM scoring with no tool access → merge → audit → render.
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPTS_DIR")"

PYTHON="$(command -v python3 || true)"
[ -x "$PYTHON" ] || PYTHON=/usr/bin/python3

CONFIG="$REPO_DIR/search_config.json"
COMPANIES="$REPO_DIR/target_companies.json"
OUTDIR="$REPO_DIR/output"
RESULTS="$OUTDIR/job-scan-results.jsonl"
MD="$OUTDIR/job-scan-results.md"
TRACKER="$OUTDIR/applications-tracker.md"
mkdir -p "$OUTDIR"

# Logs: ~/Library/Logs on macOS, XDG state dir elsewhere (never shared /tmp).
if [ -d "$HOME/Library/Logs" ]; then
    LOGDIR="$HOME/Library/Logs"
else
    LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/job-scan"
fi
mkdir -p "$LOGDIR"
RUNLOG="$LOGDIR/job-scan.log"

TODAY="$(date +%Y-%m-%d)"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$RUNLOG" 2>/dev/null || true; }

notify() {
    if command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"$1\" with title \"job-scan\"" 2>/dev/null || true
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "job-scan" "$1" 2>/dev/null || true
    fi
}

# --- One run at a time (mkdir is atomic; flock isn't available on macOS) ---
LOCK="$OUTDIR/.daily_scan.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    # Stale lock from a crashed run? Remove it if its PID is gone.
    OLD_PID="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$OLD_PID" ] && ! kill -0 "$OLD_PID" 2>/dev/null; then
        rm -rf "$LOCK"; mkdir "$LOCK"
    else
        log "SKIP another run is in progress (pid ${OLD_PID:-?})"
        exit 0
    fi
fi
echo $$ > "$LOCK/pid"

# --- Private per-run work dir ---
WORK="$(mktemp -d "${TMPDIR:-/tmp}/job-scan.XXXXXX")"
cleanup() { rm -rf "$WORK" "$LOCK"; }
trap cleanup EXIT
trap 'log "ERROR scan failed at line $LINENO"; notify "job-scan daily scan failed — see $RUNLOG"' ERR

RAW="$WORK/raw.jsonl"
CAREERS="$WORK/careers.jsonl"
TOSCORE="$WORK/to-score.jsonl"
FLAGGED="$WORK/flagged.jsonl"
PENDING="$WORK/pending.jsonl"
SCORED="$WORK/scored.jsonl"

count_lines() { "$PYTHON" -c "import sys;print(sum(1 for l in open(sys.argv[1],encoding='utf-8') if l.strip()))" "$1"; }

# Read a value from preferences.toml (fallback on error). Key/path passed as argv, not interpolated.
read_pref() {
    "$PYTHON" - "$REPO_DIR/preferences.toml" "$1" "$2" <<'PY' 2>/dev/null
import sys, tomllib, functools, operator
path, key, default = sys.argv[1:4]
try:
    with open(path, "rb") as f:
        val = functools.reduce(operator.getitem, key.split("."), tomllib.load(f))
    print(str(val).lower() if isinstance(val, bool) else val)
except Exception:
    print(default)
PY
}

log "START"

# --- Phase 1: Fetch ---
# A network failure must not block scoring of the existing backlog:
# keep whatever was fetched (possibly nothing) and carry on.
if ! "$PYTHON" "$SCRIPTS_DIR/fetch_jobtech.py" --config "$CONFIG" --out "$RAW" 2>>"$RUNLOG"; then
    [ -f "$RAW" ] || : > "$RAW"
    log "JobTech fetch incomplete (see errors above); continuing with $(count_lines "$RAW") jobs"
    notify "job-scan: JobTech fetch incomplete — check $RUNLOG"
fi

if [ -f "$COMPANIES" ]; then
    if "$PYTHON" "$SCRIPTS_DIR/fetch_careers.py" --config "$COMPANIES" --out "$CAREERS" 2>>"$RUNLOG"; then
        cat "$CAREERS" >> "$RAW"
        log "career pages OK"
    else
        # Partial results are still written on failure
        [ -s "$CAREERS" ] && cat "$CAREERS" >> "$RAW"
        log "career pages: some companies failed (see log above)"
        notify "job-scan: some career page fetches failed — check $RUNLOG"
    fi
fi

# --- Phase 2: Diff + dedup + deterministic gates ---
"$PYTHON" "$SCRIPTS_DIR/results_io.py" --mode diff --raw "$RAW" --results "$RESULTS" --out "$TOSCORE"
"$PYTHON" "$SCRIPTS_DIR/dedup.py" --in "$TOSCORE" --tracker "$TRACKER" --out "$FLAGGED"

if [ "$(read_pref gates.lang_gate true)" = "true" ]; then
    "$PYTHON" "$SCRIPTS_DIR/lang_gate.py" --in "$FLAGGED" --out "$FLAGGED" 2>>"$RUNLOG"
fi
if [ "$(read_pref gates.citizenship_gate true)" = "true" ]; then
    "$PYTHON" "$SCRIPTS_DIR/citizenship_gate.py" --in "$FLAGGED" --out "$FLAGGED" 2>>"$RUNLOG"
fi
if [ "$(read_pref gates.staffing_gate true)" = "true" ]; then
    "$PYTHON" "$SCRIPTS_DIR/pre_gate.py" --in "$FLAGGED" --out "$FLAGGED" 2>>"$RUNLOG"
fi
"$PYTHON" "$SCRIPTS_DIR/profile_gap_gate.py" --in "$FLAGGED" --out "$FLAGGED" 2>>"$RUNLOG"
"$PYTHON" "$SCRIPTS_DIR/title_gate.py" --in "$FLAGGED" --out "$FLAGGED" --config "$CONFIG" 2>>"$RUNLOG"

# --- Phase 3: Merge + render ---
"$PYTHON" "$SCRIPTS_DIR/results_io.py" --mode merge --scored "$FLAGGED" --seen "$RAW" \
  --results "$RESULTS" --md "$MD" --today "$TODAY"
"$PYTHON" "$SCRIPTS_DIR/render_html.py"

NEW_COUNT="$(count_lines "$TOSCORE")"
"$PYTHON" "$SCRIPTS_DIR/results_io.py" --mode pending --results "$RESULTS" --out "$PENDING" >/dev/null
# Re-apply the title filter to the existing backlog (picks up title_filter edits).
"$PYTHON" "$SCRIPTS_DIR/title_gate.py" --in "$PENDING" --out "$PENDING" --config "$CONFIG" 2>>"$RUNLOG"
"$PYTHON" "$SCRIPTS_DIR/results_io.py" --mode merge --scored "$PENDING" \
  --results "$RESULTS" --md "$MD" --today "$TODAY" >/dev/null
"$PYTHON" "$SCRIPTS_DIR/results_io.py" --mode pending --results "$RESULTS" --out "$PENDING" >/dev/null
PENDING_COUNT="$(count_lines "$PENDING")"
log "fetched: new=$NEW_COUNT pending=$PENDING_COUNT"

# --- Phase 4: LLM scoring (no tools; see score_llm.py) ---
AUTO_SCORE="$(read_pref schedule.auto_score true)"
MAX_BUDGET="$(read_pref schedule.max_budget_usd 1.0)"

if [ "$AUTO_SCORE" = "true" ] && [ "$PENDING_COUNT" -gt 0 ]; then
    if [ ! -f "$REPO_DIR/profile.md" ]; then
        log "auto-scoring skipped: profile.md missing (run /job-scan setup)"
    elif ! command -v claude >/dev/null 2>&1; then
        log "auto-scoring skipped: claude CLI not on PATH"
    else
        log "auto-scoring $PENDING_COUNT pending jobs (budget: \$$MAX_BUDGET)"
        if "$PYTHON" "$SCRIPTS_DIR/score_llm.py" --in "$PENDING" --out "$SCORED" \
                --budget "$MAX_BUDGET" 2>>"$RUNLOG"; then
            "$PYTHON" "$SCRIPTS_DIR/results_io.py" --mode merge --scored "$SCORED" \
              --results "$RESULTS" --md "$MD" --today "$TODAY" >/dev/null
            log "auto-scoring merged $(count_lines "$SCORED") jobs"
        else
            log "auto-scoring FAILED (non-fatal), jobs stay pending"
        fi
        # Audit is advisory: warnings go to the log, exit status ignored.
        "$PYTHON" "$SCRIPTS_DIR/audit_scores.py" --results "$RESULTS" 2>>"$RUNLOG" || true
        "$PYTHON" "$SCRIPTS_DIR/render_html.py"
        "$PYTHON" "$SCRIPTS_DIR/results_io.py" --mode pending --results "$RESULTS" --out "$PENDING" >/dev/null
        PENDING_COUNT="$(count_lines "$PENDING")"
    fi
fi

log "DONE new=$NEW_COUNT pending=$PENDING_COUNT"
notify "new=$NEW_COUNT pending=$PENDING_COUNT"
