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

A fourth question has no script: **where Devin Local reads its MCP config**.
Write a server with an unreachable URL into the path under test and look for it
in `/mcp` — it shows up as a failed connection, which is enough to prove the
file was read.

## Results — Devin CLI v3000.11.234, macOS, 2 November 2026

Run on the Devin CLI (same contract as Devin Desktop), 27 events captured.

**Tool names.** `read`, `grep`, `edit`, `exec` and `webfetch` — every one
already routed by `devinToolCategories`. No correction needed. The table's
remaining entries stay documentation-derived until a session exercises them.

**`Stop` carries the response.** The payload has `last_assistant_message` with
the agent's full response text, alongside `stop_hook_active`, `prompt_id` and
`session_id`. The field is not in the published event reference. The binary now
evaluates it as `llm` output, which keeps the coverage `post_cascade_response`
had on Cascade; the earlier gap is closed.

**Devin Local prompts for approval.** An edit raised *Allow Write(...)?* with
Allow / Accept edits / Bypass / Deny. `PermissionRequest` fires with
`tool_name`, `tool_input` and `tool_use_id`. So the Cascade premise — no
approval prompt, therefore an *ask* verdict must block — does not hold here.
Mapping *ask* onto this prompt is a follow-up, and documentation claiming
neither agent asks must be corrected.

**`SessionStart`, `SessionEnd` and `PermissionRequest` all exist**, so the
optional session-correlation work is possible.

**Devin Local reads the Cascade hooks file.** `/hooks` listed entries from
both `~/.config/devin/config.json` and `~/.codeium/windsurf/hooks.json`, and
each action visibly ran the hook twice. Wiring both hosts therefore evaluates
every event twice. `install-hooks.py` now defaults to `--host devin` and warns
on `both`.

**Payload fields observed**

| Event | Fields |
|---|---|
| `UserPromptSubmit` | `prompt`, `prompt_id`, `session_id` |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id`, `prompt_id`, `session_id` |
| `PostToolUse` | the above plus `tool_response` |
| `PermissionRequest` | `tool_name`, `tool_input`, `tool_use_id`, `prompt_id`, `session_id` |
| `Stop` | `last_assistant_message`, `stop_hook_active`, `prompt_id`, `session_id` |
| `SessionStart` | `source`, `session_id` |
| `SessionEnd` | `reason`, `prompt_id`, `session_id` |

**Blocking works through the JSON route.** A hook answering
`{"decision":"block","reason":"…"}` on stdout stopped the call — Devin printed
`Tool rejected: <reason>` and the agent repeated the reason and explained it
could not proceed. So the reason reaches the model, and `devin_block_mode`
keeps `json` as its default. The `exit2` route was not needed and stays
available as a fallback.

**No system-level hook path is honoured.** With the user config moved aside,
neither `/Library/Application Support/Devin/hooks.json` (a `{"hooks": {…}}`
object, the ENG-1639 shape) nor `/Library/Application Support/Devin/hooks.v1.json`
(the bare hooks object) was loaded; `/hooks` listed only the entries from
`~/.codeium/windsurf/hooks.json`. **An MDM deployment on Devin Local cannot
place hooks a developer is unable to remove.** Both paths that do work — the
user config and the Cascade hooks file — live in the user's home directory and
need no privileges to edit. This is a change from the Cascade deployment model
and from what the console card used to claim.

**The MCP config carries over.** A probe server written to the Cascade path
`~/.codeium/windsurf/mcp_config.json` appeared in `/mcp`, so Devin Local reads
it: an existing TrustGate MCP setup keeps working with no migration. Devin also
has its own `.devin/mcp_config.json` (project) and `~/.config/devin/` (user)
locations.

Nothing from the question list above is left open.

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
