# Devin Local verification spike

`cli/hook_devin.go` was written from the [Devin CLI hook
documentation](https://docs.devin.ai/cli/extensibility/hooks/overview), not from
a captured session. Four things are therefore assumed rather than observed. This
spike answers them in about fifteen minutes on any machine running Devin Local
(Devin Desktop or the Devin CLI — the contract is the same).

| Question | Why it matters | Answered by |
|---|---|---|
| The real `tool_name` values | `devinToolCategories` routes calls by name; an unknown name is still evaluated, but as a generic tool call rather than as shell / write / read | Check 1 |
| Whether `Stop` carries the assistant response | Cascade inspected the agent's response on `post_cascade_response`. If `Stop` does not carry it, that coverage is gone and stays documented as a gap | Check 1 |
| Which block route Devin honours | Both a stdout `decision` and exit code 2 are documented; `devin_block_mode` ships `json` by default | Check 2 |
| Whether system-level hook paths work | An MDM deployment that developers cannot disable depends on it. Devin documents project-level and user-level paths only | Check 3 |

A fourth question has no script: **where Devin Local reads its MCP config**, now
that Cascade's `~/.codeium/windsurf/mcp_config.json` may have moved. Note
whatever you find.

## Check 1 — capture the events

Register the logging hook on every event. It appends each payload to a file and
allows every action; nothing leaves the machine.

```bash
install -m 0755 scripts/devin-capture.sh /tmp/devin-capture.sh
```

Add this to `~/.config/devin/config.json` (merge the `hooks` key if the file
exists), then restart Devin:

```json
{
  "hooks": {
    "UserPromptSubmit":  [{"matcher": "", "hooks": [{"type": "command", "command": "sh /tmp/devin-capture.sh", "timeout": 10}]}],
    "PreToolUse":        [{"matcher": "", "hooks": [{"type": "command", "command": "sh /tmp/devin-capture.sh", "timeout": 10}]}],
    "PostToolUse":       [{"matcher": "", "hooks": [{"type": "command", "command": "sh /tmp/devin-capture.sh", "timeout": 10}]}],
    "Stop":              [{"matcher": "", "hooks": [{"type": "command", "command": "sh /tmp/devin-capture.sh", "timeout": 10}]}],
    "PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": "sh /tmp/devin-capture.sh", "timeout": 10}]}],
    "SessionStart":      [{"matcher": "", "hooks": [{"type": "command", "command": "sh /tmp/devin-capture.sh", "timeout": 10}]}],
    "SessionEnd":        [{"matcher": "", "hooks": [{"type": "command", "command": "sh /tmp/devin-capture.sh", "timeout": 10}]}]
  }
}
```

Then use the agent for ten minutes, deliberately covering every category the
plugin routes: have it **read** a file, **search** the repository, **edit** or
create a file, run a **shell** command, **fetch a URL**, and call an **MCP
tool** if a server is configured. Let at least one turn finish, so a `Stop`
event is captured.

```bash
python3 scripts/devin-spike-report.py /tmp/devin-events.jsonl
```

The report lists the events and tool names seen, flags any name
`devinToolCategories` does not route, and says whether the `Stop` payload holds
anything resembling the assistant response.

**What to do with it.** Add the flagged names to `devinToolCategories` in
`cli/hook_devin.go` with the right category. If the report found a response
carrier on `Stop`, open a follow-up to evaluate it as `llm` output and close the
gap recorded in the README.

## Check 2 — does a block actually block?

Same hook, answering with a block instead of allowing. Start with the default
route:

```bash
DEVIN_SPIKE_BLOCK=json
```

Set it in the environment Devin runs in (or hard-code the branch in the script),
restart, and ask the agent to run a trivial shell command.

- The action is stopped **and** the agent reports the reason → `devin_block_mode`
  keeps its default of `json`. Nothing to change.
- Nothing happens → repeat with `DEVIN_SPIKE_BLOCK=exit2`. If that blocks, the
  default must become `exit2` in `cli/config.go`.
- Neither blocks → the hook is not registered where you think it is. Run
  `/hooks` in Devin to see which files were loaded.

Note whether the reason reaches the model or only the developer's screen: the
acceptance criterion is that the reason reaches the agent.

## Check 3 — system-level hooks

This is the one that decides what can be promised for an MDM deployment.

Move the same config to the system path for the platform, remove the user-level
one, and restart Devin:

| OS | Path to try |
|---|---|
| macOS | `/Library/Application Support/Devin/hooks.json` |
| Linux | `/etc/devin/hooks.json` |
| Windows | `C:\ProgramData\Devin\hooks.json` |

Also try `hooks.v1.json` beside it, and the pre-rebrand `Windsurf` directory.

- **Hooks still fire** → the ENG-1639 deployment model carries over. Restore the
  wording in the console card and firm up the `<Warning>` in the docs page.
- **Hooks do not fire** → an MDM deployment has to write
  `~/.config/devin/config.json` per account, and a developer can remove it. Say
  so in the docs, and tell whoever owns the Santander account: the "cannot be
  disabled without root" property does not hold.

Run `/hooks` in Devin either way — it lists the loaded hooks and the files they
came from, which is the direct answer.

## Cleanup

Remove the `hooks` key you added, delete `/tmp/devin-capture.sh` and
`/tmp/devin-events.jsonl`, and restart Devin.

The capture may contain prompts, file paths and command lines from the session.
Treat it as session data: do not attach it to a public issue.
