#!/usr/bin/env python3
"""Deterministic title relevance pre-filter (pre-LLM, zero tokens).

JobTech's free-text search also matches descriptions, so broad keywords
(especially in lanes searching all occupation fields) return many postings
whose title has nothing to do with the target roles. Scoring those with the
LLM costs money for nothing.

If search_config.json has a "title_filter" list of regexes, any unscored job
whose title matches none of them gets score=5 / title_gate=true. Gated jobs
stay in the results (shown as gated), so nothing is deleted, and removing
"title_filter" stops the gate.

Usage: title_gate.py --in JOBS.jsonl --out JOBS.jsonl [--config search_config.json] [--dry-run]
"""
import argparse
import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, SCRIPT_DIR)
from config import SEARCH_CONFIG  # noqa: E402

GATE_SCORE = 5


def compile_filter(patterns):
    compiled = []
    for pat in patterns:
        try:
            compiled.append(re.compile(pat, re.IGNORECASE))
        except re.error:
            compiled.append(re.compile(re.escape(pat), re.IGNORECASE))
    return compiled


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--in", dest="inp", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--config", default=SEARCH_CONFIG)
    p.add_argument("--dry-run", action="store_true", help="Print gated titles, don't write")
    args = p.parse_args(argv)

    with open(args.config, encoding="utf-8") as f:
        patterns = json.load(f).get("title_filter") or []
    if not patterns:
        print("title_gate skipped: no title_filter in search_config.json", file=sys.stderr)
        if not args.dry_run and args.inp != args.out:
            import shutil
            shutil.copy2(args.inp, args.out)
        return 0
    filters = compile_filter(patterns)

    rows, gated = [], []
    with open(args.inp, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            rows.append(d)
            if d.get("score") is not None:
                continue
            title = d.get("title") or ""
            if not any(rx.search(title) for rx in filters):
                d["title_gate"] = True
                d["score"] = GATE_SCORE
                d["lane"] = ""
                d["reason"] = "Title gate: title matches none of search_config title_filter"
                gated.append(title)

    if args.dry_run:
        for t in sorted(gated):
            print(f"  GATED  {t}")
    print(f"{len(gated)}/{len(rows)} gated by title filter", file=sys.stderr)
    if not args.dry_run:
        with open(args.out, "w", encoding="utf-8") as f:
            for d in rows:
                f.write(json.dumps(d, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
