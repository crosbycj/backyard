# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""What Claude has cost: this month so far, by purpose, and where the month
is heading at this pace. Every call is recorded in `claude_calls`.

Run:
    uv run collector/costs.py
"""

from __future__ import annotations

import calendar
from datetime import datetime

import db


def month(conn, when: datetime | None = None) -> dict:
    """This month's calls and dollars, by purpose, with a projection."""
    when = (when or datetime.now()).astimezone()
    start = when.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    rows = conn.execute(
        "SELECT purpose, COUNT(*) AS calls, SUM(cost_usd) AS cost, "
        "SUM(input_tokens) AS input, SUM(output_tokens) AS output "
        "FROM claude_calls WHERE at >= ? GROUP BY purpose ORDER BY cost DESC",
        (start.astimezone().isoformat(timespec="seconds"),)).fetchall()
    total = sum(r["cost"] or 0 for r in rows)
    first = conn.execute("SELECT MIN(at) FROM claude_calls WHERE at >= ?",
                         (start.isoformat(timespec="seconds"),)).fetchone()[0]
    days_in_month = calendar.monthrange(when.year, when.month)[1]
    # Pace from the first recorded call, so a month that began before
    # logging doesn't look cheaper than it is.
    since = datetime.fromisoformat(first).astimezone() if first else when
    days = max((when - since).total_seconds() / 86400, 1)
    remaining = days_in_month - (when.day - 1) - when.hour / 24
    return {"month": f"{when:%B %Y}", "total": total,
            "projected": total + total / days * remaining,
            "by_purpose": [dict(r) for r in rows],
            "calls": sum(r["calls"] for r in rows), "since": since}


if __name__ == "__main__":
    m = month(db.connect())
    print(f"Claude in {m['month']}: ${m['total']:.2f} over {m['calls']} calls "
          f"(logged since {m['since']:%b %-d, %-I:%M %p})")
    for r in m["by_purpose"]:
        print(f"  {r['purpose']:<9} {r['calls']:>4} calls  ${r['cost'] or 0:>6.2f}  "
              f"({r['input'] or 0:,} in, {r['output'] or 0:,} out)")
    print(f"At this pace, the month comes to about ${m['projected']:.2f}.")
