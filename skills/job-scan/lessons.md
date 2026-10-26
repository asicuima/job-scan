# Job-Scan Lessons Learned

Operational pitfalls discovered during use. Read before troubleshooting.

## Where the data lives

Everything is relative to `PLUGIN_ROOT` (the repository root, two levels above
`SKILL.md`). The daily pipeline reads and writes `PLUGIN_ROOT/output/`:
`job-scan-results.jsonl` is the fact source; the `.md` and `.html` files are
rendered from it. Always read the `.jsonl`, never an older copy elsewhere.

## Daily scan has two log streams

- **Scheduler log** (launchd `StandardOutPath` / cron redirect): the script's
  own stdout, e.g. fetch counts and fatal errors.
- **Run log** (`RUNLOG` in `daily_scan.sh`): timestamped `log()` entries plus
  stderr from the gates, the scorer (`score_llm.py`) and the audit.

macOS: both under `~/Library/Logs/`. Linux: `~/.local/state/job-scan/`.
To check whether scoring ran, look at the run log.

## Only one daily run at a time

`daily_scan.sh` takes a lock at `output/.daily_scan.lock` and works in a
private `mktemp -d` directory. If a run crashed, the next run clears the stale
lock automatically (the recorded PID is gone).

## Unattended scoring has no tools

`score_llm.py` calls `claude -p --tools ""`. If scoring fails, the jobs simply
stay pending for the next run. Do not "fix" a failure by giving it Bash or
Write: job descriptions are untrusted web content.

## CERN LD positions have nationality restrictions

CERN Limited Duration (LD) contracts are restricted to citizens of CERN Member
States or Associate Member States. Check whether the user's nationality is on
the list; if not, cap at ≤15. Fellow/Student programmes may differ — check each
posting.
