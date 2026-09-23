#!/usr/bin/env python3
"""Merge the TrustGuard entries into a Cascade hooks.json.

Cascade runs hook commands from the workspace root, so the commands carry
absolute paths to the installed bootstrap scripts. The file may already hold
other hooks — the developer's own, or another vendor's — so this script only
ever adds or replaces the entries whose command points at a TrustGuard
bootstrap, and leaves every other entry where it was.

    install-hooks.py install HOOKS_DIR [HOOKS_JSON]
    install-hooks.py uninstall [HOOKS_JSON]

HOOKS_JSON defaults to ~/.codeium/windsurf/hooks.json, the user-level file.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

MARKER = "trustguard-hook"

# Events the binary evaluates, and whether Cascade shows the hook's stdout.
# post_cascade_response is asynchronous and does not support show_output.
EVENTS = {
    "pre_user_prompt": True,
    "pre_run_command": True,
    "pre_mcp_tool_use": True,
    "post_mcp_tool_use": True,
    "pre_write_code": True,
    "pre_read_code": True,
    "post_cascade_response": None,
}

DEFAULT_TARGET = Path.home() / ".codeium" / "windsurf" / "hooks.json"


def entry(hooks_dir: Path, show_output: bool | None) -> dict:
    sh = hooks_dir / "trustguard-hook.sh"
    ps1 = hooks_dir / "trustguard-hook.ps1"
    item = {
        "command": f'bash "{sh}"',
        "powershell": f'powershell -NoProfile -ExecutionPolicy Bypass -File "{ps1}"',
    }
    if show_output is not None:
        item["show_output"] = show_output
    return item


def load(target: Path) -> dict:
    if not target.exists():
        return {"hooks": {}}
    doc = json.loads(target.read_text() or "{}")
    if not isinstance(doc, dict):
        raise SystemExit(f"{target}: expected a JSON object")
    hooks = doc.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise SystemExit(f"{target}: \"hooks\" must be an object")
    return doc


def without_trustguard(entries: list) -> list:
    return [e for e in entries if MARKER not in json.dumps(e)]


def install(hooks_dir: Path, target: Path) -> None:
    if not (hooks_dir / "trustguard-hook.sh").is_file():
        raise SystemExit(f"missing {hooks_dir / 'trustguard-hook.sh'}")
    doc = load(target)
    for event, show_output in EVENTS.items():
        current = doc["hooks"].get(event, [])
        doc["hooks"][event] = without_trustguard(current) + [entry(hooks_dir, show_output)]
    write(doc, target)
    print(f"wrote {target}")


def uninstall(target: Path) -> None:
    if not target.exists():
        return
    doc = load(target)
    for event in list(doc["hooks"]):
        kept = without_trustguard(doc["hooks"][event])
        if kept:
            doc["hooks"][event] = kept
        else:
            del doc["hooks"][event]
    write(doc, target)
    print(f"removed TrustGuard entries from {target}")


def write(doc: dict, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(doc, indent=2) + "\n")


def main() -> None:
    args = sys.argv[1:]
    if len(args) in (2, 3) and args[0] == "install":
        hooks_dir = Path(args[1]).expanduser().resolve()
        target = Path(args[2]).expanduser() if len(args) == 3 else DEFAULT_TARGET
        install(hooks_dir, target)
    elif len(args) in (1, 2) and args[0] == "uninstall":
        uninstall(Path(args[1]).expanduser() if len(args) == 2 else DEFAULT_TARGET)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
