# Scoring Rules

Single source of truth for how jobs are scored. Used by the interactive
`/job-scan` flow (Claude reads this file) and by the unattended scorer
`scripts/score_llm.py` (embedded verbatim into the prompt).

## Inputs

- The candidate profile (`profile.md`): infer core stack and depth tiers
  (experienced vs working knowledge), years of industrial experience, target
  seniority, differentiating signals, and match strength per lane.
- Calibration examples (`calibration.jsonl`), if any: past scores the user
  corrected. Follow their direction when a new job is similar.
- The list of valid lane names from `search_config.json`.

## Pre-scoring checklist (answer each before assigning a score)

- Is the company a staffing/consulting intermediary? → cap ≤58
- Does the job carry a profile-gap flag (`*_gate=true` with a `*_gate_cap`)? → respect that cap
- Does the JD require deep expertise the profile only touches superficially? → cap ≤55
- Is the title Senior/Staff/Lead/Principal, or does the JD expect lead-level ownership? → cap ≤50
- Is the JD written entirely in Swedish? → see "Swedish JD" below

## Gate → Cap → Tier

**Gap caps (hard ceilings; take the lowest that applies):**

| Gap | Cap |
|---|---|
| Senior/lead/principal/staff role level, or experience years far beyond the profile | ≤50 |
| Profile-gap flag set by `profile_gap_gate.py` | ≤ the flag's cap |
| Missing the JD's must-have core stack (profile lacks the required depth) | ≤55 |
| Staffing agency / mass-posted consulting intermediary | ≤58 |

**Evidence level:** "used it / ran on it" is not "built / debugged it". When the
JD requires implementation, integration or troubleshooting depth in a stack,
application-level usage in the profile does not count as coverage.

**Tier anchors (after capping):**

- **80–90**: level fit + core stack coverage + direct lane match + a differentiating signal. Missing any one → below 80.
- **70–79**: in-lane with good core stack coverage; slight level mismatch or average differentiation.
- **60–69**: in-lane but with material gaps.
- **<60**: multiple gaps, staffing intermediary, or a fundamentally mismatched core stack.

## Generic principles

- **Senior cap scope:** applies to role-level expectations (senior/lead title,
  team ownership), not to "N years with technology X" requirements.
- **ML training vs deployment:** designing/training models and deploying/serving
  them are different skills. If the profile covers only one side and the JD
  needs the other, treat it as a core stack gap (≤55).
- **Swedish JD:** if the user's Swedish is not "fluent" and the JD is written
  entirely in Swedish without an explicit hard requirement, do not exclude it,
  but deduct about 10 points and say so in the reason. If the user's Swedish
  is "fluent", no deduction.
- **maybe_applied:** if `maybe_applied=true`, deduct slightly and note it.

## Output contract

For each job:

- `score`: integer 0–100
- `lane`: exactly one of the configured lane names, or `""`. Never invent variants.
- `reason`: one sentence that names both the hits AND the gaps.
