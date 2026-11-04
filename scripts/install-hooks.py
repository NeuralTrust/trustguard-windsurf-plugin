#!/usr/bin/env python3
"""Wire the TrustGuard hooks into Cascade and/or Devin Local.

Devin Desktop replaced Cascade with Devin Local, which shares the Devin CLI
hook contract. The two hosts read different files in different shapes, so this
script writes both and the binary tells the events apart at runtime:

    Cascade      ~/.codeium/windsurf/hooks.json
                 {"hooks": {"pre_run_command": [{"command": ..., ...}]}}

    Devin Local  ~/.config/devin/config.json   (user level)
                 .devin/hooks.v1.json          (project level, --project DIR)
                 {"hooks": {"PreToolUse": [{"matcher": "",
                                            "hooks": [{"type": "command", ...}]}]}}

Hook commands carry absolute paths to the installed bootstraps, because both
hosts run them from the workspace root.

Either file may already hold other hooks — the developer's own, or another
vendor's — so only entries whose command points at a TrustGuard bootstrap are
ever added or replaced; every other entry is left where it was.

    install-hooks.py install HOOKS_DIR [CASCADE_JSON] [options]
    install-hooks.py uninstall [CASCADE_JSON] [options]

Devin Local loads BOTH files: its own config and the Cascade hooks.json
(confirmed with /hooks, see docs/devin-spike.md). Wiring both on a machine
running Devin Local therefore evaluates every event twice. The default is
`devin` for that reason; `cascade` is for machines still on the Cascade agent,
and `both` is only for a fleet where some machines run each and the duplicate
evaluation is accepted.

Options:
    --host devin|cascade|both   which host to wire (default: devin)
    --devin-config PATH         Devin user config (default: ~/.config/devin/config.json)
    --project DIR               also write DIR/.devin/hooks.v1.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

MARKER = "trustguard-hook"

# Cascade events, and whether Cascade shows the hook's stdout.
# post_cascade_response is asynchronous and does not support show_output.
CASCADE_EVENTS = {
    "pre_user_prompt": True,
    "pre_run_command": True,
    "pre_mcp_tool_use": True,
    "post_mcp_tool_use": True,
    "pre_write_code": True,
    "pre_read_code": True,
    "post_cascade_response": None,
}

# Devin Local events. The matcher is a regex on tool_name; an empty matcher
# matches every tool. TrustGuard registers an empty matcher on purpose: the
# binary routes a call to the right check from its tool_name (see
# devinToolCategories in cli/hook_devin.go), so coverage does not depend on a
# regex in a config file staying in sync with the tool names Devin ships.
#
# Stop is registered but currently evaluates nothing: its payload does not
# carry the assistant response, so the output inspection Cascade did on
# post_cascade_response has no equivalent yet. It stays wired so the gap closes
# with a binary upgrade alone if the payload gains the response.
DEVIN_EVENTS = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]

HOOK_TIMEOUT_SECONDS = 30

DEFAULT_CASCADE_JSON = Path.home() / ".codeium" / "windsurf" / "hooks.json"
DEFAULT_DEVIN_CONFIG = Path.home() / ".config" / "devin" / "config.json"


# --- shared helpers ---------------------------------------------------------


def bootstrap_commands(hooks_dir: Path) -> tuple[str, str]:
    sh = hooks_dir / "trustguard-hook.sh"
    ps1 = hooks_dir / "trustguard-hook.ps1"
    return (
        f'bash "{sh}"',
        f'powershell -NoProfile -ExecutionPolicy Bypass -File "{ps1}"',
    )


def load(target: Path) -> dict:
    if not target.exists():
        return {"hooks": {}}
    doc = json.loads(target.read_text() or "{}")
    if not isinstance(doc, dict):
        raise SystemExit(f"{target}: expected a JSON object")
    hooks = doc.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise SystemExit(f'{target}: "hooks" must be an object')
    return doc


def without_trustguard(entries: list) -> list:
    return [e for e in entries if MARKER not in json.dumps(e)]


def write(doc: dict, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(doc, indent=2) + "\n")


def prune(doc: dict, target: Path) -> None:
    """Drop every TrustGuard entry, and every event left empty by that."""
    for event in list(doc["hooks"]):
        kept = without_trustguard(doc["hooks"][event])
        if kept:
            doc["hooks"][event] = kept
        else:
            del doc["hooks"][event]
    write(doc, target)
    print(f"removed TrustGuard entries from {target}")


# --- Cascade ----------------------------------------------------------------


def cascade_entry(hooks_dir: Path, show_output: bool | None) -> dict:
    command, powershell = bootstrap_commands(hooks_dir)
    item = {"command": command, "powershell": powershell}
    if show_output is not None:
        item["show_output"] = show_output
    return item


def install_cascade(hooks_dir: Path, target: Path) -> None:
    doc = load(target)
    for event, show_output in CASCADE_EVENTS.items():
        current = doc["hooks"].get(event, [])
        doc["hooks"][event] = without_trustguard(current) + [cascade_entry(hooks_dir, show_output)]
    write(doc, target)
    print(f"wrote {target} (Cascade)")


# --- Devin Local ------------------------------------------------------------


def devin_entry(hooks_dir: Path) -> dict:
    """One matcher-less entry per event.

    Devin runs the command through the platform shell, so the POSIX bootstrap
    is used on macOS and Linux and the PowerShell one on Windows. The config is
    written for the platform it is installed on.
    """
    command, powershell = bootstrap_commands(hooks_dir)
    chosen = powershell if sys.platform.startswith("win") else command
    return {
        "matcher": "",
        "hooks": [{"type": "command", "command": chosen, "timeout": HOOK_TIMEOUT_SECONDS}],
    }


def install_devin(hooks_dir: Path, target: Path, standalone: bool) -> None:
    """Write the Devin hooks.

    standalone=True writes a .devin/hooks.v1.json, where the file itself is the
    hooks object. Otherwise the hooks live under a "hooks" key in a config file.
    """
    entry = devin_entry(hooks_dir)
    if standalone:
        hooks = json.loads(target.read_text() or "{}") if target.exists() else {}
        if not isinstance(hooks, dict):
            raise SystemExit(f"{target}: expected a JSON object")
        for event in DEVIN_EVENTS:
            hooks[event] = without_trustguard(hooks.get(event, [])) + [entry]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(hooks, indent=2) + "\n")
    else:
        doc = load(target)
        for event in DEVIN_EVENTS:
            doc["hooks"][event] = without_trustguard(doc["hooks"].get(event, [])) + [entry]
        write(doc, target)
    print(f"wrote {target} (Devin Local)")


def uninstall_devin(target: Path, standalone: bool) -> None:
    if not target.exists():
        return
    if standalone:
        hooks = json.loads(target.read_text() or "{}")
        for event in list(hooks):
            kept = without_trustguard(hooks[event])
            if kept:
                hooks[event] = kept
            else:
                del hooks[event]
        target.write_text(json.dumps(hooks, indent=2) + "\n")
        print(f"removed TrustGuard entries from {target}")
    else:
        prune(load(target), target)


# --- entry point ------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False, description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument("hooks_dir", nargs="?")
    parser.add_argument("cascade_json", nargs="?")
    parser.add_argument("--host", choices=["devin", "cascade", "both"], default="devin")
    parser.add_argument("--devin-config")
    parser.add_argument("--project")
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args(argv)
    if args.help:
        raise SystemExit(__doc__)
    return args


def main() -> None:
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        raise SystemExit(__doc__)
    args = parse_args(argv)

    # On uninstall the first positional is the Cascade file, not a hooks dir.
    if args.action == "uninstall" and args.cascade_json is None:
        args.cascade_json, args.hooks_dir = args.hooks_dir, None

    cascade_json = Path(args.cascade_json).expanduser() if args.cascade_json else DEFAULT_CASCADE_JSON
    devin_config = Path(args.devin_config).expanduser() if args.devin_config else DEFAULT_DEVIN_CONFIG
    project_hooks = Path(args.project).expanduser() / ".devin" / "hooks.v1.json" if args.project else None

    if args.host == "both":
        print(
            "warning: Devin Local reads the Cascade hooks.json too, so wiring both "
            "hosts evaluates every event twice on a Devin Local machine",
            file=sys.stderr,
        )

    if args.action == "install":
        if not args.hooks_dir:
            raise SystemExit("install needs HOOKS_DIR")
        hooks_dir = Path(args.hooks_dir).expanduser().resolve()
        if not (hooks_dir / "trustguard-hook.sh").is_file():
            raise SystemExit(f"missing {hooks_dir / 'trustguard-hook.sh'}")
        if args.host in ("cascade", "both"):
            install_cascade(hooks_dir, cascade_json)
        if args.host in ("devin", "both"):
            install_devin(hooks_dir, devin_config, standalone=False)
            if project_hooks:
                install_devin(hooks_dir, project_hooks, standalone=True)
        return

    if args.host in ("cascade", "both") and cascade_json.exists():
        prune(load(cascade_json), cascade_json)
    if args.host in ("devin", "both"):
        uninstall_devin(devin_config, standalone=False)
        if project_hooks:
            uninstall_devin(project_hooks, standalone=True)


if __name__ == "__main__":
    main()
