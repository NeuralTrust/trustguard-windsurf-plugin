# TrustGuard for Windsurf

AI firewall for [Windsurf](https://windsurf.com) — now **Devin Desktop** — and
its Cascade agent. One org collector, MDM-deployed: every developer is
protected without a NeuralTrust account.

Same model as the [Claude Code](https://github.com/NeuralTrust/trustguard-claude-code-plugin),
[Codex](https://github.com/NeuralTrust/trustguard-codex-plugin) and
[Gemini CLI](https://github.com/NeuralTrust/trustguard-gemini-cli-plugin)
integrations: Cascade hooks call `trustguard-windsurf`, which maps each event to
TrustGuard `POST /v1/evaluate` and answers with an exit code.

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

`make install-hooks` copies the bootstraps to `~/.trustguard/windsurf-hooks/` and
merges absolute-path entries into `~/.codeium/windsurf/hooks.json`, leaving any
hooks already there untouched. The binary downloads itself (checksum-verified)
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
3. Deploy the system-level `hooks.json` (see
   [`docs/enterprise-hooks.json`](./docs/enterprise-hooks.json)):
   - macOS: `/Library/Application Support/Devin/hooks.json`
   - Linux: `/etc/devin/hooks.json`
   - Windows: `C:\ProgramData\Devin\hooks.json`

   Pre-rebrand installs read the same file under `Windsurf` instead of `Devin`
   (`/Library/Application Support/Windsurf/`, `/etc/windsurf/`,
   `C:\ProgramData\Windsurf\`); Devin Desktop reads both during the transition.

System-level hooks cannot be disabled without root. On the Enterprise plan the
same hooks can be distributed from the team dashboard instead. With a managed
`api_key`, `api_key`, `data_url` and `fail_mode` cannot be overridden from the
user file or the environment.

## Event → evaluation mapping

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
| `events` | — | all on | Disable events, e.g. `{"pre_read_code": false}` |

## Repository layout

| Path | Role |
|---|---|
| [`hooks/`](./hooks/) | Bootstraps: `trustguard-hook.sh` (bash) and `trustguard-hook.ps1` (PowerShell) |
| [`cli/`](./cli/) | `trustguard-windsurf` binary (Go, stdlib-only) |
| [`scripts/`](./scripts/) | `install-hooks.py` (merges `hooks.json`), release plumbing |
| [`docs/`](./docs/) | Enterprise system-level `hooks.json` example |
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

```bash
echo '{"agent_action_name":"pre_run_command","trajectory_id":"t1","tool_info":{"command_line":"echo hi"}}' \
  | ./bin/trustguard-windsurf hook; echo "exit=$?"
```

`exit=0` means allow; `exit=2` with a reason on stderr means block.

## License

Apache-2.0 — see [`LICENSE`](./LICENSE).
