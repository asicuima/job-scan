# job-scan

Automated job scanning and LLM-powered scoring for IT positions in Sweden.

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that fetches jobs from the Swedish JobTech API and target company career pages, scores them against your profile using Claude, and supports fully unattended daily runs.

## Prerequisites

- **Claude Code** CLI (with an active plan or API key)
- **Python ≥ 3.11** (uses `tomllib` from the standard library). The `python3` that ships with macOS is older; install a newer one with `brew install python`.
- **macOS** or **Linux** (for automated scheduling)

## Install

```bash
# Option 1: as a Claude Code plugin
claude plugin install https://github.com/1carusalwayswa/job-scan

# Option 2: manual
git clone https://github.com/1carusalwayswa/job-scan ~/.claude/plugins/job-scan
```

## Quick Start

```
/job-scan setup
```

The interactive setup will:
1. Generate your `profile.md` (background, skills, experience)
2. Generate `preferences.toml` (language ability, eligibility, gate toggles, schedule)
3. Generate `search_config.json` (search lanes and keywords based on your career goals)
4. Optionally generate `target_companies.json` (specific company career pages to watch)
5. Install a daily scheduler (launchd on macOS, cron on Linux)

## Usage

### Interactive (in a Claude Code session)

```
/job-scan              # Score pending backlog jobs
/job-scan setup        # First-time setup or re-configure
```

In the conversation you can also:
- "Confirm #3" / "Ignore #5" — change job status
- "Apply to #2" — prepare application materials
- "Run a full scan now" — fetch + score from scratch

### Automated (daily via launchd/cron)

After setup, `scripts/daily_scan.sh` runs daily:
1. Fetches new jobs from JobTech API
2. Runs deterministic gates (language, citizenship, staffing, occupation)
3. Merges into results and renders HTML
4. If `auto_score = true` in preferences, runs `scripts/score_llm.py`, which scores pending jobs with `claude -p --tools ""` (no tool access) within `max_budget_usd`
5. Runs `audit_scores.py` and writes any rule-violation warnings to the run log

Each run works in its own `mktemp -d` directory and holds a lock, so a manual run and the scheduled run can't overwrite each other.

Logs: `~/Library/Logs/job-scan.log` on macOS, `~/.local/state/job-scan/job-scan.log` on Linux.

### Review

Open the HTML dashboard:
```bash
python3 scripts/review_server.py   # http://localhost:8765
```
Or directly open `output/job-scan-results.html` in a browser.

## Project Structure

```
.claude-plugin/plugin.json    — Claude Code plugin metadata
skills/job-scan/SKILL.md      — Skill definition (flows, commands)
skills/job-scan/scoring_rules.md — Scoring methodology (single source of truth)
skills/job-scan/lessons.md    — Operational pitfalls
scripts/
  config.py                   — Central path resolution
  daily_scan.sh               — Daily unattended scan pipeline
  install_scheduler.sh        — Install/uninstall launchd (macOS) or cron (Linux)
  fetch_jobtech.py            — JobTech API fetcher
  fetch_careers.py            — Career page fetcher (Teamtailor, Jobylon, Workday, SuccessFactors)
  results_io.py               — JSONL fact-source read/write/merge
  dedup.py                    — Fuzzy dedup against application tracker
  lang_gate.py                — Swedish language requirement gate
  citizenship_gate.py         — Security clearance / citizenship gate
  pre_gate.py                 — Staffing company + occupation group gate
  profile_gap_gate.py         — Flags JDs needing stacks your profile lacks
  title_gate.py               — Drops irrelevant titles before scoring (search_config title_filter)
  score_llm.py                — Tool-less LLM scorer with code-enforced caps
  audit_scores.py             — Post-scoring rule-violation audit
  render_html.py              — HTML dashboard renderer
  review_server.py            — Local HTTP server for status updates
  prep_apply.py               — Prepare application directories
assets/
  staffing_companies.json     — Known staffing/temp agency patterns
  restricted_employers.json   — Security-cleared employer patterns
templates/
  profile.example.md          — Example candidate profile
  preferences.example.toml    — Example preferences with all options
```

User-generated files (gitignored):
```
profile.md                    — Your candidate profile
preferences.toml              — Your runtime preferences
search_config.json            — Your search lanes and keywords
target_companies.json         — Your target company career pages
output/                       — Results (JSONL, Markdown, HTML)
calibration.jsonl             — Scoring feedback for continuous improvement
```

## Scoring Methodology

Scoring follows a **gate → cap → tier** framework:

1. **Deterministic gates** (pre-LLM, zero tokens): language requirements, security clearance, staffing agencies, occupation groups, title relevance
2. **LLM scoring** reads your `profile.md` and applies:
   - **Cap rules**: senior/lead roles cap at ≤50, missing core stack caps at ≤55, staffing agencies cap at ≤58
   - **Evidence-level verification**: "used it" ≠ "built/debugged it"
   - **Tier anchors**: 80–90 (strong match), 70–79 (good match), 60–69 (partial), <60 (weak)
3. **Code-enforced caps**: after the LLM answers, `score_llm.py` re-applies the staffing, profile-gap and senior-title caps in code, so the model can't exceed them
4. **Calibration loop**: when you mark a score as wrong, feedback is saved to `calibration.jsonl` and used as few-shot examples in future scoring

## Security

Job descriptions are untrusted web content. Unattended scoring therefore runs
`claude -p` with **no tools** (`--tools ""`, no MCP servers), puts the postings
inside a clearly delimited untrusted block, accepts only a JSON array back and
validates every field. The worst a malicious posting can do is skew its own
score. Don't re-enable Bash/Write for the scorer.

Budget: `claude -p` only reports a budget overrun after the request has been
billed, so `score_llm.py` never starts a batch it can't afford in full (based on
the cost of earlier batches) and stops after two failures in a row.

Your `profile.md`, `preferences.toml` and results are gitignored — keep it that
way if your fork is public.

## License

MIT
