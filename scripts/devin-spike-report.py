#!/usr/bin/env python3
"""Read a Devin Local capture and answer the migration's open questions.

    devin-spike-report.py [/tmp/devin-events.jsonl]

The capture comes from scripts/devin-capture.sh. The report says which events
and tool names the host actually sent, which of those names the binary does not
yet know, and whether the Stop payload carries the assistant response — the
three things cli/hook_devin.go currently takes from documentation rather than
observation. See docs/devin-spike.md.
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

HOOK_SOURCE = Path(__file__).resolve().parent.parent / "cli" / "hook_devin.go"

# Fields that might carry the assistant response on Stop. None is documented;
# this is what the report looks for.
RESPONSE_HINTS = ("response", "message", "assistant", "transcript", "text", "content")


def known_tool_names() -> set[str]:
    """The tool names cli/hook_devin.go routes, read from the table itself."""
    try:
        source = HOOK_SOURCE.read_text()
    except OSError:
        return set()
    table = re.search(
        r"devinToolCategories = map\[string\]toolCategory\{(.*?)\n\}", source, re.S
    )
    if not table:
        return set()
    return set(re.findall(r'"([^"]+)":\s*cat', table.group(1)))


def load(path: Path) -> list[dict]:
    events = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            print(f"  ! line {n} is not JSON, skipped", file=sys.stderr)
            continue
        if isinstance(event, dict):
            events.append(event)
    return events


def section(title: str) -> None:
    print(f"\n{title}\n{'-' * len(title)}")


def main() -> None:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/devin-events.jsonl")
    if not path.is_file():
        raise SystemExit(f"no capture at {path} — run the spike first, see docs/devin-spike.md")

    events = load(path)
    if not events:
        raise SystemExit(f"{path} holds no events")

    print(f"Devin Local capture: {len(events)} events from {path}")

    section("Events seen")
    by_event = Counter(e.get("hook_event_name", "(no hook_event_name)") for e in events)
    for name, count in by_event.most_common():
        print(f"  {name:<20} {count}")

    section("Tool names seen")
    known = known_tool_names()
    tools: dict[str, Counter] = defaultdict(Counter)
    for e in events:
        name = e.get("tool_name")
        if name:
            tools[name][e.get("hook_event_name", "?")] += 1
    if not tools:
        print("  none — no tool event was captured, so exercise the agent more")
    unknown = []
    for name in sorted(tools):
        mark = "known" if (name in known or name.startswith("mcp__")) else "NOT ROUTED"
        if mark == "NOT ROUTED":
            unknown.append(name)
        where = ", ".join(f"{k}×{v}" for k, v in tools[name].items())
        print(f"  {name:<28} {mark:<11} ({where})")

    if unknown:
        print("\n  Add these to devinToolCategories in cli/hook_devin.go:")
        for name in unknown:
            print(f'    "{name}": cat???,')
    elif tools:
        print("\n  Every captured tool name is already routed.")

    section("Stop: does it carry the assistant response?")
    stops = [e for e in events if e.get("hook_event_name") == "Stop"]
    if not stops:
        print("  no Stop event captured — end a turn and capture again")
    else:
        fields: set[str] = set()
        for e in stops:
            fields |= set(e)
        print(f"  {len(stops)} Stop events, fields: {', '.join(sorted(fields))}")
        candidates = sorted(
            f for f in fields
            if any(h in f.lower() for h in RESPONSE_HINTS) and f != "hook_event_name"
        )
        if candidates:
            print(f"  POSSIBLE RESPONSE CARRIER: {', '.join(candidates)}")
            print("  Inspect the values: if one holds the assistant text, the")
            print("  post_cascade_response coverage gap can be closed.")
        else:
            print("  No field looks like the response. The gap documented in the")
            print("  README stands: output inspection is not available on Devin Local.")

    section("All payload fields, per event")
    shapes: dict[str, set[str]] = defaultdict(set)
    for e in events:
        shapes[e.get("hook_event_name", "?")] |= set(e)
    for name in sorted(shapes):
        print(f"  {name}: {', '.join(sorted(shapes[name]))}")

    section("Still to answer by hand")
    print("  - Did a block actually stop the action, and in which mode")
    print("    (DEVIN_SPIKE_BLOCK=json vs exit2)?")
    print("  - Are system-level hook paths honoured?")
    print("  - Where does Devin Local read its MCP config?")
    print("  See docs/devin-spike.md.")


if __name__ == "__main__":
    main()
