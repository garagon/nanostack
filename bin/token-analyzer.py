#!/usr/bin/env python3
"""
Token usage analyzer for Claude Code sessions.
Reads ~/.claude/projects/ JSONL files, aggregates token usage per session/subagent,
calculates cost, and detects anomalies.

No external dependencies — stdlib only.
"""

import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude" / "projects"

# Pricing per 1M tokens: (input, output)
PRICING = {
    "claude-opus-4-6": (15.0, 75.0),
    "claude-opus-4-5-20250918": (15.0, 75.0),
    "opus-4": (15.0, 75.0),
    "opus-4-6": (15.0, 75.0),
    "claude-sonnet-4-6": (3.0, 15.0),
    "claude-sonnet-4-5-20241022": (3.0, 15.0),
    "sonnet-4": (3.0, 15.0),
    "sonnet-4-6": (3.0, 15.0),
    "claude-haiku-4-5-20251001": (0.80, 4.0),
    "haiku-4-5": (0.80, 4.0),
    "gpt-4o": (2.5, 10.0),
    "gpt-4.1": (2.0, 8.0),
    "o3": (2.0, 8.0),
}
DEFAULT_PRICING = (3.0, 15.0)  # sonnet fallback


def get_pricing(model):
    """Get (input_price, output_price) per 1M tokens for a model."""
    if not model:
        return DEFAULT_PRICING
    # Try exact match first, then prefix match
    if model in PRICING:
        return PRICING[model]
    for key, val in PRICING.items():
        if model.startswith(key) or key.startswith(model):
            return val
    return DEFAULT_PRICING


def calculate_cost(tokens, model):
    """Calculate USD cost from token counts and model.

    Anthropic cache pricing:
    - cache_read: 10% of input price
    - cache_creation: 125% of input price
    - regular input: 100% of input price
    """
    input_price, output_price = get_pricing(model)
    input_tokens = tokens.get("input", 0)
    cache_creation = tokens.get("cache_creation", 0)
    cache_read = tokens.get("cache_read", 0)
    output_tokens = tokens.get("output", 0)

    cost = (
        (input_tokens / 1_000_000) * input_price
        + (cache_creation / 1_000_000) * input_price * 1.25
        + (cache_read / 1_000_000) * input_price * 0.10
        + (output_tokens / 1_000_000) * output_price
    )
    return round(cost, 4)


def parse_session(jsonl_path):
    """Parse a single JSONL session file. Returns session dict or None."""
    tokens = defaultdict(int)
    model = None
    session_id = None
    branch = None
    ts_first = None
    ts_last = None

    try:
        with open(jsonl_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue

                ts = obj.get("timestamp")
                if ts:
                    if not ts_first:
                        ts_first = ts
                    ts_last = ts

                if not session_id:
                    session_id = obj.get("sessionId")
                if not branch:
                    branch = obj.get("gitBranch")

                if obj.get("type") == "assistant":
                    usage = obj.get("message", {}).get("usage", {})
                    tokens["input"] += usage.get("input_tokens", 0)
                    tokens["cache_creation"] += usage.get("cache_creation_input_tokens", 0)
                    tokens["cache_read"] += usage.get("cache_read_input_tokens", 0)
                    tokens["output"] += usage.get("output_tokens", 0)

                    if not model:
                        model = obj.get("message", {}).get("model")

    except (OSError, PermissionError):
        return None

    total = sum(tokens.values())
    if total == 0:
        return None

    return {
        "file": str(jsonl_path),
        "session_id": session_id or jsonl_path.stem,
        "model": model,
        "branch": branch,
        "timestamp_start": ts_first,
        "timestamp_end": ts_last,
        "tokens": dict(tokens),
        "tokens_total": total,
        "cost_usd": calculate_cost(tokens, model),
    }


def parse_session_with_subagents(jsonl_path):
    """Parse a main session and its subagents."""
    session = parse_session(jsonl_path)
    if not session:
        return None

    subagents = []
    subagents_dir = jsonl_path.parent / jsonl_path.stem / "subagents"
    if subagents_dir.is_dir():
        for sub_file in sorted(subagents_dir.glob("*.jsonl")):
            sub = parse_session(sub_file)
            if sub:
                sub["subagent_file"] = sub_file.name
                subagents.append(sub)

    session["subagents"] = subagents
    session["subagent_count"] = len(subagents)
    session["subagent_tokens"] = sum(s["tokens_total"] for s in subagents)
    session["subagent_cost_usd"] = round(sum(s["cost_usd"] for s in subagents), 4)

    return session


def resolve_project_dir(cwd=None):
    """Convert a working directory path to its Claude Code project directory name."""
    if cwd is None:
        cwd = os.getcwd()
    # Claude Code encodes: /Users/dev/project → -Users-dev-project
    encoded = cwd.replace("/", "-")
    return PROJECTS_DIR / encoded


def get_project_name(dir_name):
    """Convert directory name to readable project name."""
    # Strip leading -Users-<username>- prefix
    name = dir_name
    home = str(Path.home())
    prefix = home.replace("/", "-") + "-"
    if name.startswith(prefix):
        name = name[len(prefix):]
    elif name.startswith("-"):
        name = name.lstrip("-")
    return name or dir_name


def parse_cutoff(since_arg):
    """Parse --since argument. Returns datetime or None."""
    if not since_arg:
        return None
    # Try "Nd" format (days)
    if since_arg.endswith("d") and since_arg[:-1].isdigit():
        days = int(since_arg[:-1])
        return datetime.now(timezone.utc) - timedelta(days=days)
    # Try ISO date
    try:
        dt = datetime.fromisoformat(since_arg)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except ValueError:
        return None


def session_in_range(session, cutoff):
    """Check if session started after cutoff."""
    if not cutoff or not session.get("timestamp_start"):
        return True
    try:
        ts = datetime.fromisoformat(session["timestamp_start"].replace("Z", "+00:00"))
        return ts >= cutoff
    except ValueError:
        return True


def scan_project(project_dir, cutoff=None):
    """Scan a single project directory for sessions."""
    sessions = []
    if not project_dir.is_dir():
        return sessions
    for jsonl_file in sorted(project_dir.glob("*.jsonl")):
        session = parse_session_with_subagents(jsonl_file)
        if session and session_in_range(session, cutoff):
            sessions.append(session)
    return sessions


def scan_all_projects(cutoff=None):
    """Scan all projects. Returns dict of project_name → sessions."""
    projects = {}
    if not PROJECTS_DIR.is_dir():
        return projects
    for project_dir in sorted(PROJECTS_DIR.iterdir()):
        if not project_dir.is_dir():
            continue
        sessions = scan_project(project_dir, cutoff)
        if sessions:
            name = get_project_name(project_dir.name)
            projects[name] = sessions
    return projects


def aggregate(sessions):
    """Aggregate token counts across sessions."""
    totals = defaultdict(int)
    subagent_tokens = 0
    subagent_count = 0
    subagent_cost = 0.0
    total_cost = 0.0

    for s in sessions:
        for key in ("input", "cache_creation", "cache_read", "output"):
            totals[key] += s["tokens"].get(key, 0)
        total_cost += s["cost_usd"]
        subagent_tokens += s["subagent_tokens"]
        subagent_count += s["subagent_count"]
        subagent_cost += s["subagent_cost_usd"]

    grand_total = sum(totals.values())
    cache_total = totals["cache_read"] + totals["cache_creation"]
    cache_eff = round(totals["cache_read"] / cache_total * 100) if cache_total > 0 else 0
    subagent_pct = round(subagent_tokens / grand_total * 100) if grand_total > 0 else 0

    return {
        "sessions": len(sessions),
        "subagent_sessions": subagent_count,
        "tokens": {
            "input": totals["input"],
            "cache_creation": totals["cache_creation"],
            "cache_read": totals["cache_read"],
            "output": totals["output"],
            "total": grand_total,
        },
        "cost_usd": round(total_cost, 2),
        "subagent_cost_usd": round(subagent_cost, 2),
        "subagent_tokens": subagent_tokens,
        "cache_efficiency_pct": cache_eff,
        "subagent_pct": subagent_pct,
        "avg_per_session": round(grand_total / len(sessions)) if sessions else 0,
    }


def detect_anomalies(sessions):
    """Detect anomalous sessions. Returns list of alerts."""
    if len(sessions) < 2:
        return []

    alerts = []
    outlier_ratio = float(os.environ.get("NANO_TOKEN_OUTLIER_RATIO", "3"))
    subagent_pct_threshold = float(os.environ.get("NANO_TOKEN_SUBAGENT_PCT", "60"))
    freq_ratio = float(os.environ.get("NANO_TOKEN_FREQ_RATIO", "4"))

    # Session outlier detection
    totals = [s["tokens_total"] for s in sessions]
    avg_tokens = sum(totals) / len(totals)

    if avg_tokens > 0:
        for s in sessions:
            ratio = s["tokens_total"] / avg_tokens
            if ratio >= outlier_ratio:
                alerts.append({
                    "type": "session_outlier",
                    "session_id": s["session_id"],
                    "tokens": s["tokens_total"],
                    "avg_tokens": round(avg_tokens),
                    "ratio": round(ratio, 1),
                    "message": f"Session used {ratio:.1f}x the average. Check for loops.",
                })

    # Subagent heavy detection (pct of total = parent + all subagents)
    for s in sessions:
        if s["subagent_count"] == 0:
            continue
        session_total = s["tokens_total"] + s["subagent_tokens"]
        if session_total == 0:
            continue
        for sub in s["subagents"]:
            pct = sub["tokens_total"] / session_total * 100
            if pct >= subagent_pct_threshold:
                alerts.append({
                    "type": "subagent_heavy",
                    "session_id": s["session_id"],
                    "subagent": sub.get("subagent_file", "unknown"),
                    "tokens": sub["tokens_total"],
                    "pct_of_session": round(pct),
                    "message": f"Single subagent consumed {pct:.0f}% of total session tokens.",
                })

    # High frequency detection
    timestamps = []
    for s in sessions:
        ts_str = s.get("timestamp_start")
        if ts_str:
            try:
                timestamps.append(datetime.fromisoformat(ts_str.replace("Z", "+00:00")))
            except ValueError:
                pass

    if len(timestamps) >= 4:
        timestamps.sort()
        total_hours = (timestamps[-1] - timestamps[0]).total_seconds() / 3600
        if total_hours > 0:
            avg_per_hour = len(timestamps) / total_hours
            # Check last hour
            one_hour_ago = datetime.now(timezone.utc) - timedelta(hours=1)
            recent = [t for t in timestamps if t >= one_hour_ago]
            if len(recent) > 0 and avg_per_hour > 0:
                recent_ratio = len(recent) / avg_per_hour
                if recent_ratio >= freq_ratio and len(recent) >= 4:
                    alerts.append({
                        "type": "high_frequency",
                        "sessions_last_hour": len(recent),
                        "avg_sessions_per_hour": round(avg_per_hour, 1),
                        "message": f"{len(recent)} sessions in the last hour (avg {avg_per_hour:.1f}). Possible automation loop.",
                    })

    return alerts


def fmt(n):
    """Format number with commas."""
    return f"{n:,}"


def print_terminal(project_name, sessions, agg, alerts, top_n, show_subagents):
    """Print human-readable terminal report."""
    since_info = ""
    if sessions:
        first_ts = sessions[0].get("timestamp_start", "")[:10]
        last_ts = sessions[-1].get("timestamp_start", "")[:10]
        if first_ts:
            since_info = f" ({first_ts} to {last_ts})"

    print(f"\nToken Usage Report — {project_name}{since_info}")
    print("=" * 60)
    print()
    print(f"  Sessions: {agg['sessions']}  |  Subagents: {agg['subagent_sessions']}  |  "
          f"Total: {fmt(agg['tokens']['total'])} tokens  |  Est. cost: ${agg['cost_usd']:.2f}")
    print()

    # Top sessions
    sorted_sessions = sorted(sessions, key=lambda s: s["tokens_total"], reverse=True)[:top_n]
    print(f"  Top {min(top_n, len(sorted_sessions))} sessions:")
    for i, s in enumerate(sorted_sessions, 1):
        date = s.get("timestamp_start", "")[:10] or "?"
        branch = s.get("branch") or "?"
        subs = f"({s['subagent_count']} subagents)" if s["subagent_count"] > 0 else ""
        print(f"    {i:2d}. [{date}] {branch:<30s} {fmt(s['tokens_total']):>12s} tok  ${s['cost_usd']:>6.2f}  {subs}")
    print()

    # Token breakdown
    t = agg["tokens"]
    total = t["total"] or 1
    print("  Token breakdown:")
    print(f"    Input:          {fmt(t['input']):>12s}  ({t['input']*100//total:2d}%)")
    print(f"    Cache creation: {fmt(t['cache_creation']):>12s}  ({t['cache_creation']*100//total:2d}%)")
    ce = agg['cache_efficiency_pct']
    print(f"    Cache read:     {fmt(t['cache_read']):>12s}  ({t['cache_read']*100//total:2d}%)  <- cache efficiency: {ce}%")
    print(f"    Output:         {fmt(t['output']):>12s}  ({t['output']*100//total:2d}%)")
    print()
    print(f"  Subagent cost:    ${agg['subagent_cost_usd']:.2f} ({agg['subagent_pct']}% of total)")
    print(f"  Avg per session:  {fmt(agg['avg_per_session'])} tokens")

    # Subagent detail
    if show_subagents:
        print()
        print("  Subagent breakdown:")
        all_subs = []
        for s in sessions:
            for sub in s["subagents"]:
                all_subs.append((s["session_id"][:8], sub))
        all_subs.sort(key=lambda x: x[1]["tokens_total"], reverse=True)
        for parent_id, sub in all_subs[:20]:
            print(f"    {parent_id}  {sub.get('subagent_file', '?'):<40s}  {fmt(sub['tokens_total']):>10s} tok  ${sub['cost_usd']:.2f}")

    # Alerts
    if alerts:
        print()
        print("  ALERTS:")
        for a in alerts:
            print(f"    [{a['type']}] {a['message']}")

    print()


def output_json(project_name, sessions, agg, alerts, top_n, since, show_subagents):
    """Output JSON report."""
    sorted_sessions = sorted(sessions, key=lambda s: s["tokens_total"], reverse=True)[:top_n]

    result = {
        "project": project_name,
        "period": {
            "since": since or "all",
            "sessions_from": sessions[0].get("timestamp_start") if sessions else None,
            "sessions_until": sessions[-1].get("timestamp_start") if sessions else None,
        },
        **agg,
    }

    result["top_sessions"] = [
        {
            "session_id": s["session_id"],
            "branch": s.get("branch"),
            "date": (s.get("timestamp_start") or "")[:10],
            "tokens_total": s["tokens_total"],
            "cost_usd": s["cost_usd"],
            "subagent_count": s["subagent_count"],
            "subagent_tokens": s["subagent_tokens"],
            "model": s.get("model"),
        }
        for s in sorted_sessions
    ]

    if show_subagents:
        all_subs = []
        for s in sessions:
            for sub in s["subagents"]:
                all_subs.append({
                    "parent_session": s["session_id"][:8],
                    "file": sub.get("subagent_file", "?"),
                    "tokens_total": sub["tokens_total"],
                    "cost_usd": sub["cost_usd"],
                    "model": sub.get("model"),
                })
        all_subs.sort(key=lambda x: x["tokens_total"], reverse=True)
        result["subagent_detail"] = all_subs[:30]

    if alerts:
        result["alerts"] = alerts
        result["status"] = "warning"
    else:
        result["status"] = "ok"

    print(json.dumps(result, indent=2))


def output_check(sessions, alerts):
    """Output anomaly check result (for --check)."""
    result = {
        "status": "warning" if alerts else "ok",
        "sessions_scanned": len(sessions),
        "alerts": alerts,
    }
    print(json.dumps(result, indent=2))


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Claude Code token usage analyzer")
    parser.add_argument("--all", action="store_true", help="Scan all projects")
    parser.add_argument("--since", type=str, default=None, help="Filter: '7d' or '2026-04-01'")
    parser.add_argument("--json", action="store_true", help="JSON output")
    parser.add_argument("--top", type=int, default=10, help="Show top N sessions (default: 10)")
    parser.add_argument("--subagents", action="store_true", help="Show subagent breakdown")
    parser.add_argument("--check", action="store_true", help="Anomaly detection mode")
    parser.add_argument("--project-dir", type=str, default=None, help="Claude project dir (auto-resolved if omitted)")
    parser.add_argument("--project-name", type=str, default=None, help="Project display name")
    args = parser.parse_args()

    cutoff = parse_cutoff(args.since)

    # Check if Claude Code session logs exist
    if not PROJECTS_DIR.is_dir():
        msg = "Claude Code session logs not found. This feature requires Claude Code (reads ~/.claude/projects/)."
        if args.json or args.check:
            print(json.dumps({"status": "skipped", "sessions_scanned": 0, "alerts": [], "message": msg}))
        else:
            print(msg)
        return

    if args.all:
        projects = scan_all_projects(cutoff)
        all_sessions = []
        for name, sess_list in projects.items():
            all_sessions.extend(sess_list)

        if not all_sessions:
            if args.json or args.check:
                print(json.dumps({"status": "ok", "sessions_scanned": 0, "alerts": [], "message": "No sessions found"}))
            else:
                print("No sessions found in ~/.claude/projects/")
            return

        agg = aggregate(all_sessions)
        alerts = detect_anomalies(all_sessions) if args.check or not args.json else detect_anomalies(all_sessions)

        if args.check:
            output_check(all_sessions, alerts)
        elif args.json:
            output_json("all-projects", all_sessions, agg, alerts, args.top, args.since, args.subagents)
        else:
            print_terminal("all-projects", all_sessions, agg, alerts, args.top, args.subagents)
            # Per-project summary
            print("  Per-project breakdown:")
            proj_aggs = []
            for name, sess_list in projects.items():
                pa = aggregate(sess_list)
                proj_aggs.append((name, pa))
            proj_aggs.sort(key=lambda x: x[1]["tokens"]["total"], reverse=True)
            for name, pa in proj_aggs:
                print(f"    {name:<40s} {fmt(pa['tokens']['total']):>12s} tok  ${pa['cost_usd']:>7.2f}  ({pa['sessions']} sessions)")
            print()
    else:
        # Single project
        if args.project_dir:
            project_dir = Path(args.project_dir)
        else:
            project_dir = resolve_project_dir()

        project_name = args.project_name or get_project_name(project_dir.name)
        sessions = scan_project(project_dir, cutoff)

        if not sessions:
            if args.json or args.check:
                print(json.dumps({"status": "ok", "sessions_scanned": 0, "alerts": [], "message": "No sessions found"}))
            else:
                print(f"No sessions found for {project_name}")
                print(f"  Looked in: {project_dir}")
            return

        agg = aggregate(sessions)
        alerts = detect_anomalies(sessions)

        if args.check:
            output_check(sessions, alerts)
        elif args.json:
            output_json(project_name, sessions, agg, alerts, args.top, args.since, args.subagents)
        else:
            print_terminal(project_name, sessions, agg, alerts, args.top, args.subagents)


if __name__ == "__main__":
    main()
