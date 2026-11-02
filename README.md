# TrustGuard for Windsurf

AI firewall for [Windsurf](https://windsurf.com) — now **Devin Desktop** — on
both of its agents: **Devin Local** (current) and **Cascade** (through July
2026). One org collector, MDM-deployed: every developer is protected without a
NeuralTrust account.

Same model as the [Claude Code](https://github.com/NeuralTrust/trustguard-claude-code-plugin),
[Codex](https://github.com/NeuralTrust/trustguard-codex-plugin) and
[Gemini CLI](https://github.com/NeuralTrust/trustguard-gemini-cli-plugin)
integrations: the agent's hooks call `trustguard-windsurf`, which maps each
event to TrustGuard `POST /v1/evaluate` and answers in that host's contract.

One binary serves both hosts. It tells them apart by the event field the
payload carries — `hook_event_name` is Devin Local, `agent_action_name` is
Cascade — so a single install covers a fleet mid-migration.

## The Devin Local hook contract

Devin Local shares the [Devin CLI hook
contract](https://docs.devin.ai/cli/extensibility/hooks/overview): the event
arrives as JSON on stdin keyed by `hook_event_name`, and the hook answers with
JSON on stdout or an exit code.

| Answer | Effect |
|---|---|
| `{"decision":"block","reason":"…"}` on stdout | The action is blocked and the reason reaches the agent |
| `hookSpecificOutput.additionalContext` | Text injected into the agent's context (allowed with a notice) |
| exit `2` | The action is blocked, reason read from stderr |
| exit `0`, no output | The action proceeds |

Both block routes are documented and `devin_block_mode` selects between them
(`json` by default, `exit2` for the Cascade-style route) so a deployment can
switch without a rebuild.

Unlike Cascade, Devin Local **does** prompt the developer for approval, has a
`PermissionRequest` event carrying `tool_name` and `tool_input`, and lets a
`PreToolUse` hook rewrite the call through `hookSpecificOutput.updatedInput`.
None of the three is used yet: an **Ask** verdict still blocks by default
(`ask_action`) and a **Transform** verdict still blocks by default
(`transform_action`). Mapping *ask* onto the real approval prompt, and
*transform* onto `updatedInput`, is the obvious next step now that both are
confirmed to exist (see [`docs/devin-spike.md`](./docs/devin-spike.md)).

## The Cascade hook contract

Cascade runs each hook command through `bash -c` (macOS, Linux) or
`powershell -Command` (Windows), writes the event as JSON on stdin, and reads
the verdict from the exit code:

| Exit code | Pre-hook | Post-hook |
|---|---|---|
| `0` | The action proceeds | Nothing happens |
| `2` | The action is **blocked**; the agent reads the reason on stderr | The action already ran; the agent still reads stderr |
| other | The action proceeds | Nothing happens |

There is no approval prompt and no input rewriting, so a TrustGuard **Ask**
verdict blocks by default (`ask_action`) and a **Transform** verdict blocks by
default (`transform_action`).

## Install

### Pilot

```bash
git clone https://github.com/NeuralTrust/trustguard-windsurf-plugin.git
cd trustguard-windsurf-plugin
make install-hooks
```

`make install-hooks` copies the bootstraps to `~/.trustguard/windsurf-hooks/`
and merges absolute-path entries into both hosts' user-level config —
`~/.config/devin/config.json` for Devin Local and
`~/.codeium/windsurf/hooks.json` for Cascade — leaving any hooks already there
untouched. `scripts/install-hooks.py --project DIR` writes a project-level
`DIR/.devin/hooks.v1.json` instead of the user config.

`HOST` selects the agent and defaults to `devin`. **Devin Local loads the
Cascade `hooks.json` as well**, so `HOST=both` makes it evaluate every event
twice; use it only for a fleet where some machines still run Cascade and the
duplicate evaluation is accepted. `HOST=cascade` is for those machines alone. The binary downloads itself (checksum-verified)
on the first hook event. `make install-local` does the same with a local build.

Then write `~/.trustguard/windsurf.json` (`chmod 600`) and reload Windsurf:

```json
{
  "data_url": "https://<trustguard-data-plane>",
  "api_key": "tgk_…",
  "fail_mode": "closed"
}
```

### Enterprise (MDM)

1. Install the bootstraps under a fixed directory, e.g.
   `/Library/Application Support/TrustGuard/windsurf-hooks/`, and optionally put
   `trustguard-windsurf` on the PATH.
2. Drop a managed config with the org Windsurf collector key:
   - macOS: `/Library/Application Support/TrustGuard/windsurf.json`
   - Linux: `/etc/trustguard/windsurf.json`
   - Windows: `%ProgramData%\TrustGuard\windsurf.json`
3. Deploy the hooks. For Devin Local, see
   [`docs/enterprise-hooks-devin.json`](./docs/enterprise-hooks-devin.json);
   for Cascade, [`docs/enterprise-hooks.json`](./docs/enterprise-hooks.json).
   The Cascade system-level paths are:
   - macOS: `/Library/Application Support/Devin/hooks.json`
   - Linux: `/etc/devin/hooks.json`
   - Windows: `C:\ProgramData\Devin\hooks.json`

   Pre-rebrand installs read the same file under `Windsurf` instead of `Devin`
   (`/Library/Application Support/Windsurf/`, `/etc/windsurf/`,
   `C:\ProgramData\Windsurf\`); Devin Desktop reads both during the transition.

   > **Unverified for Devin Local.** The Devin CLI documents project-level
   > (`.devin/hooks.v1.json`, `.devin/config.json`) and user-level
   > (`~/.config/devin/config.json`, `%APPDATA%\devin\config.json`) hook
   > paths only. Whether Devin Local also reads the system-level paths above
   > has to be confirmed on a real install. If it does not, an MDM deployment
   > must write the user-level config per account, and the hooks are no longer
   > undisableable without root.

System-level hooks cannot be disabled without root. On the Enterprise plan the
same hooks can be distributed from the team dashboard instead. With a managed
`api_key`, `api_key`, `data_url` and `fail_mode` cannot be overridden from the
user file or the environment.

## Event → evaluation mapping (Devin Local)

Devin Local sends one `PreToolUse`/`PostToolUse` event for every tool and names
the tool in `tool_name`; the binary routes it to the matching check. The
registered matcher is empty on purpose, so a tool name the binary does not know
yet still reaches it rather than silently escaping coverage.

| Devin event | `tool_name` | TrustGuard protocol | Direction |
|---|---|---|---|
| `UserPromptSubmit` | — | `llm` | input |
| `PreToolUse` | `exec`, `get_output`, `write_to_process`, `kill_shell` | `mcp` tools/call | input |
| `PreToolUse` | `write`, `edit`, `apply_patch`, `notebook_edit` | `mcp` tools/call | input |
| `PreToolUse` | `read`, `grep`, `glob`, `notebook_read` | `mcp` tools/call | input |
| `PreToolUse` | `webfetch` | `mcp` tools/call | input |
| `PreToolUse` | `mcp__<server>__<tool>` | `mcp` tools/call | input |
| `PostToolUse` | any of the above | `mcp` result | output |
| `Stop` | — | `llm` (the assistant response) | output |

Shell commands travel as `tools/call` like every other tool: as plain input
TrustGuard would score a command as a user prompt (jailbreak, toxicity,
moderation) rather than as tool arguments (ENG-1620).

`session_id` is Devin's own; `prompt_id` and every other field travel in
`attributes.devin`. `attributes.tool` carries the tool name, its category and,
for shell calls, the command line. `consumer_id` is still set per device or per
user through MDM.

`read`, `grep`, `edit`, `exec` and `webfetch` were captured from a live Devin
Local session and route correctly. The rest of the table comes from the Devin
CLI documentation, which warns that the set varies by CLI mode, model and
enabled integrations. Every name lives in one table (`devinToolCategories` in
`cli/hook_devin.go`) and nowhere else, so a later capture is applied in a single
place — see [`docs/devin-spike.md`](./docs/devin-spike.md) for the procedure.
A name the table does not know is still evaluated, as a generic tool call.

### The assistant response

Cascade's `post_cascade_response` carried the agent's response text. The Devin
event reference lists only `stop_hook_active` for `Stop`, but the payload Devin
Local actually sends also carries `last_assistant_message` with the full
response, so the same coverage is kept: the response is evaluated as `llm`
output.

It is recorded, never blocked. The turn is over by then, so a block would not
retract what the developer has already read — and on `Stop` a block tells Devin
to keep working, which loops when the condition cannot be satisfied. This
mirrors what `post_cascade_response` did on Cascade.

The field is not in the published reference, so a Devin release could rename it.
If that happens the hook stops evaluating rather than misbehaving, and
[`docs/devin-spike.md`](./docs/devin-spike.md) re-captures the payload.

## Event → evaluation mapping (Cascade)

| Cascade event | TrustGuard protocol | Direction | Verdict |
|---|---|---|---|
| `pre_user_prompt` | `llm` | input | Block with exit 2 |
| `pre_run_command` | `all`, `{ "input": "<command>" }` | input | Block with exit 2. `tool.name` is `run_command`, `tool.command` the command line |
| `pre_mcp_tool_use` | `mcp` tools/call | input | Block with exit 2. `attributes.mcp.server` names the server |
| `pre_write_code` | `mcp` tools/call `write_code` with `file_path` and `edits` | input | Block with exit 2 |
| `pre_read_code` | `mcp` tools/call `read_code` with `file_path` | input | Block with exit 2 |
| `post_mcp_tool_use` | `mcp` result | output | Cannot undo the call. On a block the agent is told to treat the result as untrusted |
| `post_cascade_response` | `llm` | output | Recorded in Activity only (asynchronous hook) |

`post_run_command` carries no command output, so it is not evaluated.

`session_id` is Cascade's `trajectory_id`; `attributes.model.name` is its
`model_name`; the rest of the hook payload travels in `attributes.windsurf`.
Cascade does not put the user in the payload: set `consumer_id` per device or
per user through MDM for attribution.

## Configuration

`~/.trustguard/windsurf.json` (or `TRUSTGUARD_WINDSURF_CONFIG`), environment
variables winning unless managed mode locks the field:

| Field | Env | Default | Meaning |
|---|---|---|---|
| `data_url` | `TRUSTGUARD_DATA_URL` | `http://localhost:8081` | TrustGuard data-plane base URL |
| `api_key` | `TRUSTGUARD_API_KEY` | — | Collector API key (`tgk_…`). Without it every event is allowed |
| `fail_mode` | `TRUSTGUARD_FAIL_MODE` | `open` | `open` allows, `closed` blocks when TrustGuard is unreachable |
| `ask_action` | `TRUSTGUARD_ASK_ACTION` | `deny` | What an `ask` verdict does: `deny` or `allow` with a notice |
| `transform_action` | `TRUSTGUARD_TRANSFORM_ACTION` | `deny` | What a DLP `transform` verdict does: `deny` or `allow`; `ask` follows `ask_action` |
| `report_notice` | — | `true` | Print report-only findings; Cascade shows them with `show_output` |
| `timeout_ms` | `TRUSTGUARD_TIMEOUT_MS` | `5000` | Per-call evaluate timeout |
| `max_content_bytes` | — | `262144` | Tool result and response bytes sent to the guard |
| `consumer_id` | `TRUSTGUARD_CONSUMER_ID` | — | Sent as `consumer_id` |
| `devin_block_mode` | `TRUSTGUARD_DEVIN_BLOCK_MODE` | `json` | How Devin Local is told to block: `json` (stdout decision) or `exit2` |
| `events` | — | all on | Disable events, e.g. `{"pre_read_code": false}`. Cascade event names keep working on Devin Local: `pre_read_code` disables `PreToolUse` for read tools, and so on |

## Repository layout

| Path | Role |
|---|---|
| [`hooks/`](./hooks/) | Bootstraps: `trustguard-hook.sh` (bash) and `trustguard-hook.ps1` (PowerShell) |
| [`cli/`](./cli/) | `trustguard-windsurf` binary (Go, stdlib-only) |
| [`scripts/`](./scripts/) | `install-hooks.py` (merges both hosts' configs), release plumbing |
| [`docs/`](./docs/) | Enterprise system-level hook config examples per host, and the Devin Local verification spike |
| [`.github/workflows/`](./.github/workflows/) | CI + the release state machine that pins and publishes the platform binaries |

```bash
make build            # ./bin/trustguard-windsurf
make test             # go test -race ./cli/ + bootstrap tests
make install-hooks    # bootstraps + user hooks.json
make uninstall-local  # remove the TrustGuard entries and the local install
make dist VERSION=0.1.0
```

## Releasing the binary

`main` requires a pull request, so the **Release** workflow never writes to it.
On every push it compares the version in `cli/main.go` with the `v*` tags:

| State of `main` | Action |
|---|---|
| Pinned version is already tagged | **prepare** — bump the patch, build, pin the new checksums and push the `release/vX.Y.Z` branch |
| Pinned version has no tag | **publish** — rebuild, verify the pins still match, tag and publish the GitHub Release |

Merge your work, open the release pull request from the link the run summary
leaves, then merge it. The first push finds `0.1.0` with empty checksums, so the
publish job pushes `release/v0.1.0` with the real ones; merging that publishes
`v0.1.0`.

## Verify

Devin Local:

```bash
echo '{"hook_event_name":"PreToolUse","tool_name":"exec","tool_input":{"command":"echo hi"}}' \
  | ./bin/trustguard-windsurf hook
```

No output means allow; `{"decision":"block","reason":"…"}` means block.

Cascade:

```bash
echo '{"agent_action_name":"pre_run_command","trajectory_id":"t1","tool_info":{"command_line":"echo hi"}}' \
  | ./bin/trustguard-windsurf hook; echo "exit=$?"
```

`exit=0` means allow; `exit=2` with a reason on stderr means block.

## License

Apache-2.0 — see [`LICENSE`](./LICENSE).
