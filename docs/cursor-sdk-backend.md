# Cursor SDK backend (bridge stub)

Status: the shell-callable bridge (`bin/fm-cursor-bridge.mjs`, Track T2) exists and is verified in offline dry-run mode; the selectable backend adapter (`bin/backends/cursor-sdk.sh`, Track T3) and its dispatcher wiring do not exist yet.
This document is the contract stub the T3 adapter codes against, in the shape `docs/codex-app-backend.md` requires: firstmate backends are Bash entry points, so a Cursor SDK backend needs a supported shell-callable transport that creates an agent, sends to it, reads its state, and stops it, with status landing in `state/<id>.status`.
`bin/fm-cursor-bridge.mjs` is that transport: a Node.js ESM CLI wrapping [`@cursor/sdk`](https://cursor.com/docs/sdk/typescript).

The authoritative, one-owner statement of the verb interface, flags, and status mapping is the header comment at the top of `bin/fm-cursor-bridge.mjs`, mirrored by `node bin/fm-cursor-bridge.mjs --help`.
This document summarizes that contract and records the runtime note and dry-run verification; it does not restate the mechanics flag-by-flag.

## Shell-callable JSON verb contract

The bridge is invoked as `node bin/fm-cursor-bridge.mjs <verb> [flags]`.
Every verb prints exactly one JSON object to stdout and nothing else there; diagnostics go to stderr.
Every object carries an `ok` boolean.
On failure the object is `{"ok":false,"error":"<message>","verb":"<verb>"}` and the process exits non-zero: `2` for usage errors, `1` for runtime failures.
A caller parses stdout as JSON and branches on `ok`; it never screen-scrapes prose.

| Verb | Purpose | Key flags | Prints |
| --- | --- | --- | --- |
| `create` | Start an agent and run its first turn | `--cwd`, `--state-file` (local), `--prompt`/`--prompt-file`, `--id`, `--model`, `--effort`, `--runtime`, `--session-file` | `{ok, agent_id, session_ref, runtime, model}` |
| `send` | Send a prompt or steer line as a new run | `--session` or `--agent-id`+`--cwd`, `--prompt`/`--prompt-file` | `{ok, agent_id, run_id, status}` |
| `read` | Return transcript/state for `fm-peek` / `fm-crew-state` | `--session` or `--agent-id`+`--cwd`, `--limit` | `{ok, agent_id, runtime, status, archived, model, summary, last_status_line, transcript[]}` |
| `kill` | Cancel any active run and archive (or `--delete`) the agent | `--session` or `--agent-id`+`--cwd`, `--delete` | `{ok, agent_id, archived, deleted}` |

`create` persists a session JSON at `session_ref` holding `agent_id`, `runtime`, `cwd`, `model`, `state_file`, and `id`.
That file is enough for `send`, `read`, and `kill` to reattach to the same agent from a fresh process, mirroring `@cursor/sdk`'s durable-agent flow (`Agent.resume(agentId)` after the local process restarted).
The model defaults to `composer-2.5` and is overridable per invocation with `--model`; `--effort` is passed as a model parameter (`ModelSelection.params`), whose id is model-specific and overridable with `--effort-param-id`.

## Status return channel (local runtime)

While a `create` or `send` turn runs in the local runtime, the bridge consumes the `@cursor/sdk` event stream and appends firstmate status lines to `--state-file`, mapping SDK run lifecycle to firstmate states:

- run started/running -> `working: cursor <runtime> turn started`
- run finished -> `working: cursor turn finished (idle)`
- run error -> `failed: <error message>`
The lines are deliberately sparse (one at turn start, one at turn end), because every append wakes firstmate.
A finished turn is not a finished task: the bridge never writes a `done:` line, because task completion is firstmate's judgment via `fm-crew-state`, not a transport detail.
Request events are not mapped to firstmate decisions until the bridge has a verified human-input payload shape to surface.

## Local vs. cloud runtime

Runtime is a flag, not a rewrite: `--runtime local` (the default) or `--runtime cloud`, picked by which key the bridge passes to `Agent.create` (`local: { cwd }` vs. `cloud`), reusing the same `CURSOR_API_KEY`.
The four verbs and their JSON shapes are identical across runtimes; only two things differ.
First, the local runtime owns status-file writing (above); a cloud agent surfaces through Cursor's Agents Window and its own polling, so the bridge does not synthesize local status lines for it.
Second, reattach routing differs: local agents route by `--cwd`, cloud agents (`bc-` ids) route by API key.
Keeping the contract runtime-agnostic is deliberate so a later cloud-backed backend is a flag on the same bridge, not a second implementation.

## Offline dry-run mode

Pass `--dry-run` (or set `FM_CURSOR_BRIDGE_DRY_RUN=1`) to drive a built-in, file-backed fake SDK instead of `@cursor/sdk`.
Dry-run needs no `@cursor/sdk`, no network, and no `CURSOR_API_KEY`, and it is what `tests/fm-cursor-bridge.test.sh` and CI exercise.
The fake persists agent state to a sidecar JSON file (default under the process cwd, or `FM_CURSOR_BRIDGE_DRYRUN_DIR`), so create/send/read/kill work deterministically across separate invocations exactly as the real durable-agent flow does.

## Dependency note

Firstmate's `bin/` Node tooling manages its dependencies from a root `package.json` with a committed `package-lock.json`; `node_modules/` is gitignored.
`@cursor/sdk` is a pinned dependency there (currently `1.0.23`, the latest published, non-deprecated release; requires node >= 22.13).
It is still imported lazily and only on the live (non-dry-run) path, so the dry-run path and the test suite never require it, and CI (which does not run `npm install`) stays deterministic; the offline suite exercises the built-in fake SDK.
Run `npm install` at the repo root once to populate `node_modules` for live use; the live path then loads the real SDK and fails cleanly with a JSON error only if it truly cannot be resolved.

Track T3 should not wire `cursor-sdk` into `FM_BACKEND_KNOWN` / `FM_BACKEND_SPAWN` for production use until a full green live smoke (create -> send -> read -> kill against a real agent with `CURSOR_API_KEY` set, status landing in `state/<id>.status`) is recorded here with date, version, exact commands, and exact output, per the backend-verification-doc convention.
A live call needs `CURSOR_API_KEY` and network, which the offline verification below deliberately does not use; that full smoke is left for whoever has a key.

## Dry-run verification

Date: 2026-07-08.
Environment: node v24.16.0, macOS, `@cursor/sdk` 1.0.23 pinned in the root `package.json` and not installed in this isolated worktree.
The dry-run path below uses the built-in fake SDK and no network or `CURSOR_API_KEY`; a full live smoke is deferred to whoever has a key (see the dependency note above).

Commands and results:

```text
$ node bin/fm-cursor-bridge.mjs --help
fm-cursor-bridge.mjs - firstmate <-> Cursor SDK bridge
Usage: node bin/fm-cursor-bridge.mjs <verb> [flags]
... (verb contract) ...

$ node bin/fm-cursor-bridge.mjs create --dry-run --cwd <repo> --state-file <state>/demo.status --id demo --prompt "build the thing" --session-file <sess>
{"ok":true,"verb":"create","agent_id":"agent-dry-...","session_ref":"<sess>","runtime":"local","model":"composer-2.5","first_run_id":"run-dry-...","first_run_status":"finished"}

$ node bin/fm-cursor-bridge.mjs send --dry-run --session <sess> --prompt "also add tests"
{"ok":true,"verb":"send","agent_id":"agent-dry-...","run_id":"run-dry-...","status":"finished"}

$ node bin/fm-cursor-bridge.mjs read --dry-run --session <sess>
{"ok":true,"verb":"read","agent_id":"agent-dry-...","runtime":"local","status":"finished","archived":false,"model":"composer-2.5","summary":"...","last_status_line":"working: cursor turn finished (idle)","transcript":[{"role":"user","text":"also add tests"},{"role":"assistant","text":"..."}]}

$ node bin/fm-cursor-bridge.mjs kill --dry-run --session <sess>
{"ok":true,"verb":"kill","agent_id":"agent-dry-...","archived":true,"deleted":false}

$ cat <state>/demo.status
working: cursor local turn started
working: cursor turn finished (idle)
```

`tests/fm-cursor-bridge.test.sh` pins this contract (16 cases: the four verbs end to end, reattach by session and by agent-id, prompt-required create, cloud-runtime flag parity, request-event status behavior, kill cancellation, stream/wait failure status writes, stable kill shape, the usage-error exit codes, the status-file writes, and the clean live-path failure when `@cursor/sdk` is absent).
