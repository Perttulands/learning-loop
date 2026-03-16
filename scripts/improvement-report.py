#!/usr/bin/env python3
"""Generate a learning-loop agent improvement report from SQLite data."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable


POLIS_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_WINDOW_DAYS = 14
DEFAULT_WEEKLY_BUCKETS = 3
DEFAULT_SEGMENT_LIMIT = 8


@dataclass(frozen=True)
class Segment:
    agent: str
    model: str
    lineage: str

    @property
    def label(self) -> str:
        parts = [f"agent={self.agent}", f"model={self.model}"]
        if self.lineage and self.lineage != "n/a":
            parts.append(f"lineage={self.lineage}")
        return ", ".join(parts)


@dataclass(frozen=True)
class Run:
    outcome: str
    duration_s: int | None
    timestamp: datetime
    segment: Segment


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate an agent improvement report from learning-loop data."
    )
    parser.add_argument(
        "--db",
        default=os.environ.get("LOOP_DB", ""),
        help="Path to a specific loop.db file. Defaults to $LOOP_DB when set; otherwise auto-discovers populated databases.",
    )
    parser.add_argument(
        "--window-days",
        type=int,
        default=DEFAULT_WINDOW_DAYS,
        help=f"Rolling trend window in days (default: {DEFAULT_WINDOW_DAYS}).",
    )
    parser.add_argument(
        "--weekly-buckets",
        type=int,
        default=DEFAULT_WEEKLY_BUCKETS,
        help=f"Number of weekly snapshots to print (default: {DEFAULT_WEEKLY_BUCKETS}).",
    )
    parser.add_argument(
        "--segment-limit",
        type=int,
        default=DEFAULT_SEGMENT_LIMIT,
        help=f"Maximum number of segments to print per section (default: {DEFAULT_SEGMENT_LIMIT}).",
    )
    return parser.parse_args()


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def parse_timestamp(raw: str) -> datetime:
    value = raw.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value).astimezone(timezone.utc)


def load_metadata(raw: str) -> dict:
    if not raw:
        return {}
    try:
        loaded = json.loads(raw)
        return loaded if isinstance(loaded, dict) else {}
    except json.JSONDecodeError:
        return {}


def derive_segment(agent: str, model: str, metadata_raw: str) -> Segment:
    metadata = load_metadata(metadata_raw)
    lineage = (
        metadata.get("template")
        or metadata.get("lineage")
        or metadata.get("prompt_lineage")
        or "n/a"
    )
    return Segment(
        agent=agent.strip() or "unknown",
        model=model.strip() or "unknown",
        lineage=str(lineage).strip() or "n/a",
    )


def discover_databases(explicit_db: str | None) -> list[Path]:
    candidates: list[Path] = []

    def add(path: Path) -> None:
        resolved = path.resolve()
        if resolved not in candidates:
            candidates.append(resolved)

    if explicit_db:
        add(Path(explicit_db))
        return candidates

    fixed = [
        POLIS_ROOT / ".learning-loop" / "loop.db",
        POLIS_ROOT / ".polis" / "learning" / "loop.db",
        POLIS_ROOT / "projects" / ".learning-loop" / "loop.db",
        POLIS_ROOT / "tools" / "learning-loop" / ".learning-loop" / "loop.db",
        POLIS_ROOT / "tools" / ".learning-loop" / "loop.db",
    ]
    for path in fixed:
        add(path)

    for base in (POLIS_ROOT / "tools", POLIS_ROOT / "projects", POLIS_ROOT / "agents"):
        if not base.exists():
            continue
        for path in base.rglob("loop.db"):
            if path.parent.name == ".learning-loop":
                add(path)

    return candidates


def inspect_database(path: Path) -> tuple[int, datetime | None]:
    if not path.exists():
        return 0, None
    try:
        conn = sqlite3.connect(path)
        row = conn.execute("select count(*), max(timestamp) from runs").fetchone()
    except sqlite3.Error:
        return 0, None
    finally:
        try:
            conn.close()
        except Exception:
            pass

    count = int(row[0] or 0)
    latest = parse_timestamp(row[1]) if row and row[1] else None
    return count, latest


def choose_database(candidates: Iterable[Path], explicit: bool) -> tuple[Path | None, list[tuple[Path, int, datetime | None]]]:
    inspected: list[tuple[Path, int, datetime | None]] = []
    for path in candidates:
        count, latest = inspect_database(path)
        inspected.append((path, count, latest))

    if explicit:
        return (inspected[0][0] if inspected else None), inspected

    populated = [entry for entry in inspected if entry[1] > 0]
    if populated:
        populated.sort(key=lambda item: (item[1], item[2] or datetime.min.replace(tzinfo=timezone.utc)), reverse=True)
        return populated[0][0], inspected

    existing = [entry for entry in inspected if entry[0].exists()]
    if existing:
        return existing[0][0], inspected
    return None, inspected


def load_runs(db_path: Path) -> list[Run]:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        """
        select outcome, duration_s, timestamp, agent, model, metadata
        from runs
        order by timestamp
        """
    ).fetchall()
    conn.close()

    runs: list[Run] = []
    for row in rows:
        runs.append(
            Run(
                outcome=row["outcome"],
                duration_s=row["duration_s"],
                timestamp=parse_timestamp(row["timestamp"]),
                segment=derive_segment(row["agent"] or "", row["model"] or "", row["metadata"] or ""),
            )
        )
    return runs


def load_pattern_rows(db_path: Path, start_at: datetime) -> list[sqlite3.Row]:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            """
            select
              p.name as pattern_name,
              p.impact as impact,
              r.agent as agent,
              r.model as model,
              r.metadata as metadata
            from pattern_matches pm
            join patterns p on p.id = pm.pattern_id
            join runs r on r.id = pm.run_id
            where r.timestamp >= ?
            order by p.name
            """,
            (start_at.strftime("%Y-%m-%dT%H:%M:%SZ"),),
        ).fetchall()
    except sqlite3.Error:
        rows = []
    finally:
        conn.close()
    return rows


def week_start(day_value: date) -> date:
    return day_value - timedelta(days=day_value.weekday())


def trend_rows(runs: list[Run], start_day: date, end_day: date) -> dict[Segment, list[tuple[date, int, float]]]:
    grouped: dict[Segment, dict[date, list[Run]]] = defaultdict(lambda: defaultdict(list))
    for run in runs:
        run_day = run.timestamp.date()
        if start_day <= run_day <= end_day:
            grouped[run.segment][run_day].append(run)

    output: dict[Segment, list[tuple[date, int, float]]] = {}
    for segment, by_day in grouped.items():
        points: list[tuple[date, int, float]] = []
        for day_value in sorted(by_day):
            bucket = by_day[day_value]
            successes = sum(1 for run in bucket if run.outcome == "success")
            points.append((day_value, len(bucket), successes / len(bucket)))
        output[segment] = points
    return output


def duration_rows(runs: list[Run], start_day: date, end_day: date) -> dict[Segment, list[tuple[date, int, float]]]:
    grouped: dict[Segment, dict[date, list[int]]] = defaultdict(lambda: defaultdict(list))
    for run in runs:
        run_day = run.timestamp.date()
        if not (start_day <= run_day <= end_day):
            continue
        if run.outcome == "success" and run.duration_s is not None:
            grouped[run.segment][run_day].append(run.duration_s)

    output: dict[Segment, list[tuple[date, int, float]]] = {}
    for segment, by_day in grouped.items():
        points: list[tuple[date, int, float]] = []
        for day_value in sorted(by_day):
            bucket = by_day[day_value]
            points.append((day_value, len(bucket), sum(bucket) / len(bucket)))
        output[segment] = points
    return output


def weekly_rows(runs: list[Run], end_day: date, weekly_buckets: int) -> dict[Segment, list[tuple[date, int, float]]]:
    end_week = week_start(end_day)
    start_week = end_week - timedelta(days=7 * (weekly_buckets - 1))
    grouped: dict[Segment, dict[date, list[Run]]] = defaultdict(lambda: defaultdict(list))
    for run in runs:
        bucket = week_start(run.timestamp.date())
        if start_week <= bucket <= end_week:
            grouped[run.segment][bucket].append(run)

    week_keys = [start_week + timedelta(days=7 * idx) for idx in range(weekly_buckets)]
    output: dict[Segment, list[tuple[date, int, float]]] = {}
    for segment, by_week in grouped.items():
        points: list[tuple[date, int, float]] = []
        for week_key in week_keys:
            bucket = by_week.get(week_key, [])
            if not bucket:
                continue
            successes = sum(1 for run in bucket if run.outcome == "success")
            points.append((week_key, len(bucket), successes / len(bucket)))
        output[segment] = points
    return output


def summarize_patterns(pattern_rows: list[sqlite3.Row]) -> dict[Segment, list[tuple[str, str, int]]]:
    grouped: dict[Segment, dict[tuple[str, str], int]] = defaultdict(lambda: defaultdict(int))
    for row in pattern_rows:
        segment = derive_segment(row["agent"] or "", row["model"] or "", row["metadata"] or "")
        key = (row["pattern_name"], row["impact"])
        grouped[segment][key] += 1

    output: dict[Segment, list[tuple[str, str, int]]] = {}
    for segment, pattern_counts in grouped.items():
        ranked = sorted(
            ((name, impact, count) for (name, impact), count in pattern_counts.items()),
            key=lambda item: (-item[2], item[0]),
        )
        output[segment] = ranked
    return output


def segment_total_runs(runs: list[Run], start_day: date, end_day: date) -> dict[Segment, int]:
    totals: dict[Segment, int] = defaultdict(int)
    for run in runs:
        if start_day <= run.timestamp.date() <= end_day:
            totals[run.segment] += 1
    return totals


def pick_segments(data: dict[Segment, list], totals: dict[Segment, int], limit: int) -> list[Segment]:
    segments = list(data)
    segments.sort(key=lambda segment: (totals.get(segment, 0), segment.label), reverse=True)
    return segments[:limit]


def format_rate(value: float) -> str:
    return f"{value * 100:.1f}%"


def format_duration(seconds: float) -> str:
    return f"{seconds:.1f}s"


def improvement_call(total_runs: int) -> str:
    if total_runs < 10:
        return f"insufficient volume to call improvement ({total_runs} runs in window; need 10+)"
    return f"enough volume for trend interpretation ({total_runs} runs in window)"


def print_no_data(inspected: list[tuple[Path, int, datetime | None]]) -> None:
    print("Learning Loop Improvement Report")
    print(f"Generated: {now_utc().strftime('%Y-%m-%dT%H:%M:%SZ')}")
    print("")
    print("Status: no data yet")
    if inspected:
        print("Checked databases:")
        for path, count, latest in inspected:
            latest_text = latest.strftime("%Y-%m-%d") if latest else "n/a"
            print(f"  - {path} (runs={count}, latest={latest_text})")
    else:
        print("No candidate databases were found.")
    print("Run `loop ingest` or pass `--db /path/to/loop.db` once data exists.")


def main() -> int:
    args = parse_args()
    candidates = discover_databases(args.db)
    selected_db, inspected = choose_database(candidates, explicit=bool(args.db))
    if selected_db is None:
        print_no_data(inspected)
        return 0

    count, latest = inspect_database(selected_db)
    if count == 0 or latest is None:
        print_no_data(inspected)
        return 0

    runs = load_runs(selected_db)
    if not runs:
        print_no_data(inspected)
        return 0

    anchor_day = latest.date()
    trend_start = anchor_day - timedelta(days=args.window_days - 1)
    weekly_data = weekly_rows(runs, anchor_day, args.weekly_buckets)
    success_data = trend_rows(runs, trend_start, anchor_day)
    duration_data = duration_rows(runs, trend_start, anchor_day)
    totals = segment_total_runs(runs, trend_start, anchor_day)
    segment_order = pick_segments(success_data or weekly_data or duration_data, totals, args.segment_limit)
    pattern_start = latest - timedelta(days=29)
    patterns = summarize_patterns(load_pattern_rows(selected_db, pattern_start))

    print("Learning Loop Improvement Report")
    print(f"Generated: {now_utc().strftime('%Y-%m-%dT%H:%M:%SZ')}")
    print(f"Database: {selected_db}")
    print(
        "Window: "
        f"{trend_start.isoformat()} to {anchor_day.isoformat()} "
        f"(anchored to latest run on {anchor_day.isoformat()})"
    )
    print(f"Total runs in selected DB: {len(runs)}")
    print("")

    print("Metric 1: Run Success Rate")
    if not success_data:
        print("  No runs in the rolling window.")
    else:
        for segment in segment_order:
            points = success_data.get(segment, [])
            if not points:
                continue
            print(f"  Segment: {segment.label}")
            print(f"  14d assessment: {improvement_call(totals.get(segment, 0))}")
            for day_value, run_count, success_rate in points:
                print(
                    f"    {day_value.isoformat()}  success_rate={format_rate(success_rate)}  runs={run_count}"
                )
            print("  Weekly snapshots:")
            for week_value, run_count, success_rate in weekly_data.get(segment, []):
                print(
                    f"    week_of={week_value.isoformat()}  success_rate={format_rate(success_rate)}  runs={run_count}"
                )
            print("")

    print("Metric 2: Time To Successful Completion")
    if not duration_data:
        print("  No successful runs with duration data in the rolling window.")
    else:
        duration_segments = pick_segments(duration_data, totals, args.segment_limit)
        for segment in duration_segments:
            points = duration_data.get(segment, [])
            if not points:
                continue
            print(f"  Segment: {segment.label}")
            for day_value, run_count, avg_duration in points:
                print(
                    f"    {day_value.isoformat()}  avg_success_duration={format_duration(avg_duration)}  successful_runs={run_count}"
                )
            print("")

    print("Metric 3: Failure Pattern Recurrence Rate")
    print(f"  30d window start: {pattern_start.date().isoformat()}")
    if not patterns:
        print("  No failure pattern matches recorded in the 30d window.")
    else:
        for segment in pick_segments(patterns, totals, args.segment_limit):
            print(f"  Segment: {segment.label}")
            for name, impact, hits in patterns.get(segment, [])[:5]:
                denominator = totals.get(segment, 0) or 1
                print(
                    f"    {name}  impact={impact}  hits_30d={hits}  hits_per_run={hits / denominator:.3f}"
                )
            print("")

    return 0


if __name__ == "__main__":
    sys.exit(main())
