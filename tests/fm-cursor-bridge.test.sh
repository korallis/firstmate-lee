#!/usr/bin/env bash
# Behavior tests for bin/fm-cursor-bridge.mjs - the firstmate <-> Cursor SDK
# bridge (Track T2).
#
# A live @cursor/sdk call needs CURSOR_API_KEY and network, so these tests
# exercise ONLY the deterministic offline path: --dry-run drives a built-in
# file-backed fake SDK, so the four verbs (create/send/read/kill) run end to
# end with no dependency installed, no network, and no API key. They pin:
#   - the shell-callable JSON contract (one JSON object per verb, `ok` flag),
#   - argument parsing and usage-error exit codes,
#   - the local-runtime status return channel (lines land in state/<id>.status),
#   - reattach via the persisted session file across separate invocations,
#   - transcript/state readback and archive-on-kill,
#   - that the live path fails cleanly (JSON error) when @cursor/sdk is absent.
# The dry-run store is isolated per case via FM_CURSOR_BRIDGE_DRYRUN_DIR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || fail "node is required to test the Cursor SDK bridge"

BRIDGE="$ROOT/bin/fm-cursor-bridge.mjs"
TMP_ROOT=$(fm_test_tmproot fm-cursor-bridge)

# jget <json> <dotted.key>: print a field; arrays print their length, missing
# prints empty. Uses node so no jq dependency is required.
jget() {
  J="$1" node -e '
    const o = JSON.parse(process.env.J);
    const v = process.argv[1].split(".").reduce((a, p) => (a == null ? undefined : a[p]), o);
    process.stdout.write(v === undefined ? "" : Array.isArray(v) ? String(v.length) : String(v));
  ' "$2"
}

# assert_valid_json <json> <msg>
assert_valid_json() {
  J="$1" node -e 'JSON.parse(process.env.J)' 2>/dev/null || fail "$2 (invalid JSON): $1"
}

# assert_one_line <output> <msg>: verb output must be exactly one line on stdout.
assert_one_line() {
  local n
  n=$(printf '%s' "$1" | grep -c '' 2>/dev/null || echo 0)
  [ "$n" -eq 1 ] || fail "$2 (expected 1 stdout line, got $n): $1"
}

# new_case <name>: create an isolated case dir with repo/, state/, store/ and
# echo the dir. The caller must then point the dry-run store at "<dir>/store"
# with `use_case <dir>` from the TEST's own shell - an `export` inside this
# command-substituted function would not reach the parent shell.
new_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/repo" "$d/state" "$d/store"
  printf '%s\n' "$d"
}

# use_case <dir>: isolate the dry-run store for this case in the parent shell.
use_case() {
  export FM_CURSOR_BRIDGE_DRYRUN_DIR="$1/store"
}

# ---------------------------------------------------------------------------
test_help_prints_contract() {
  local out rc
  out=$(node "$BRIDGE" --help); rc=$?
  expect_code 0 "$rc" "--help exits 0"
  assert_contains "$out" "Usage: node bin/fm-cursor-bridge.mjs" "--help prints usage"
  assert_contains "$out" "create" "--help lists create verb"
  assert_contains "$out" "kill" "--help lists kill verb"
  pass "--help prints the verb contract"
}

# create/send/read/kill end to end over one persisted session.
test_lifecycle_end_to_end() {
  local d; d=$(new_case lifecycle); use_case "$d"
  local sf="$d/state/demo.status" sess="$d/demo.session.json"
  local out agent_id

  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" --state-file "$sf" --id demo \
    --prompt "build the thing" --session-file "$sess")
  assert_valid_json "$out" "create output"
  assert_one_line "$out" "create is one JSON line"
  [ "$(jget "$out" ok)" = "true" ] || fail "create ok!=true: $out"
  agent_id=$(jget "$out" agent_id)
  case "$agent_id" in agent-*) : ;; *) fail "create agent_id not agent-*: $agent_id" ;; esac
  local sref; sref=$(jget "$out" session_ref)
  [ -n "$sref" ] || fail "create session_ref empty: $out"
  assert_present "$sess" "session file persisted"
  [ "$sref" -ef "$sess" ] || fail "create session_ref is not the persisted session file: $sref vs $sess"
  [ "$(jget "$out" runtime)" = "local" ] || fail "create runtime!=local: $out"
  assert_grep "working: cursor local turn started" "$sf" "create wrote turn-start status"
  assert_grep "working: cursor turn finished (idle)" "$sf" "create wrote turn-finished status"

  out=$(node "$BRIDGE" send --dry-run --session "$sess" --prompt "also add tests")
  assert_valid_json "$out" "send output"
  [ "$(jget "$out" ok)" = "true" ] || fail "send ok!=true: $out"
  [ "$(jget "$out" status)" = "finished" ] || fail "send status!=finished: $out"
  case "$(jget "$out" run_id)" in run-*) : ;; *) fail "send run_id missing: $out" ;; esac

  out=$(node "$BRIDGE" read --dry-run --session "$sess")
  assert_valid_json "$out" "read output"
  [ "$(jget "$out" ok)" = "true" ] || fail "read ok!=true: $out"
  [ "$(jget "$out" transcript)" -ge 2 ] || fail "read transcript too short: $out"
  assert_contains "$out" "also add tests" "read transcript includes the sent prompt"
  [ -n "$(jget "$out" last_status_line)" ] || fail "read last_status_line empty: $out"

  out=$(node "$BRIDGE" kill --dry-run --session "$sess")
  assert_valid_json "$out" "kill output"
  [ "$(jget "$out" ok)" = "true" ] || fail "kill ok!=true: $out"
  [ "$(jget "$out" archived)" = "true" ] || fail "kill archived!=true: $out"
  [ "$(jget "$out" deleted)" = "false" ] || fail "kill deleted!=false: $out"

  out=$(node "$BRIDGE" read --dry-run --session "$sess")
  [ "$(jget "$out" archived)" = "true" ] || fail "read after kill archived!=true: $out"
  pass "create/send/read/kill run end to end in dry-run with valid JSON"
}

# Reattach via --agent-id + --cwd (no session file) must also work.
test_reattach_by_agent_id() {
  local d; d=$(new_case reattach); use_case "$d"
  local sf="$d/state/r.status" sess="$d/r.session.json" out agent_id
  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" --state-file "$sf" --id r \
    --prompt hi --session-file "$sess")
  agent_id=$(jget "$out" agent_id)
  out=$(node "$BRIDGE" read --dry-run --agent-id "$agent_id" --cwd "$d/repo")
  [ "$(jget "$out" ok)" = "true" ] || fail "read by agent-id ok!=true: $out"
  [ "$(jget "$out" agent_id)" = "$agent_id" ] || fail "read by agent-id mismatch: $out"
  pass "reattach by --agent-id/--cwd works without a session file"
}

test_send_resume_preserves_session_model() {
  local d; d=$(new_case resumemodel); use_case "$d"
  local sf="$d/state/m.status" sess="$d/m.session.json" out model effort effort_param
  model="cursor-review-model"
  effort="high"
  effort_param="reasoning_effort"
  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" --state-file "$sf" --id m \
    --model "$model" --effort "$effort" --effort-param-id "$effort_param" --prompt hi --session-file "$sess")
  [ "$(jget "$out" model)" = "$model" ] || fail "create did not report custom model: $out"
  SESSION="$sess" MODEL="$model" EFFORT="$effort" EFFORT_PARAM="$effort_param" node -e '
    const fs = require("node:fs");
    const got = JSON.parse(fs.readFileSync(process.env.SESSION, "utf8"));
    if (got.model_selection?.id !== process.env.MODEL) throw new Error("model_selection id " + got.model_selection?.id);
    const param = got.model_selection?.params?.[0];
    if (param?.id !== process.env.EFFORT_PARAM || param?.value !== process.env.EFFORT) {
      throw new Error("model_selection params " + JSON.stringify(got.model_selection?.params));
    }
  ' || fail "session did not persist full model selection"

  out=$(node "$BRIDGE" send --dry-run --session "$sess" --prompt "resume with same model")
  [ "$(jget "$out" ok)" = "true" ] || fail "send with custom session model ok!=true: $out"

  out=$(node "$BRIDGE" read --dry-run --session "$sess")
  [ "$(jget "$out" model)" = "$model" ] || fail "read lost custom session model: $out"
  assert_contains "$out" "resume with same model" "custom-model resumed send reached transcript"
  pass "send resumes with the persisted session model selection"
}

test_live_resume_forwards_model_to_sdk() {
  local d; d=$(new_case livestub); use_case "$d"
  local bridge_dir="$d/bin" sdk_dir="$d/node_modules/@cursor/sdk"
  local sf="$d/state/live.status" sess="$d/live.session.json" capture="$d/resume.json"
  local out model effort effort_param
  model="cursor-live-model"
  effort="medium"
  effort_param="reasoning_effort"
  mkdir -p "$bridge_dir" "$sdk_dir"
  cp "$BRIDGE" "$bridge_dir/fm-cursor-bridge.mjs"
  cat > "$sdk_dir/package.json" <<'JSON'
{"type":"module","main":"index.js"}
JSON
  cat > "$sdk_dir/index.js" <<'JS'
import { writeFile } from "node:fs/promises";

export const Agent = {
  async resume(agentId, opts) {
    await writeFile(process.env.FM_CURSOR_STUB_CAPTURE, JSON.stringify({ agentId, opts }) + "\n");
    return {
      agentId,
      async send(message) {
        return {
          id: "run-live-stub",
          status: "finished",
          stream: async function* stream() {
            yield { type: "assistant", message: { content: [{ type: "text", text: `stub reply: ${message}` }] } };
          },
          wait: async () => ({ id: "run-live-stub", status: "finished", result: "stub done" }),
          cancel: async () => {},
        };
      },
      close: () => {},
    };
  },
};
JS
  node -e '
    const fs = require("node:fs");
    const [file, cwd, model, stateFile] = process.argv.slice(1);
    fs.writeFileSync(file, JSON.stringify({
      schema: "fm-cursor-bridge/session@1",
      agent_id: "agent-live-stub",
      runtime: "local",
      cwd,
      model,
      model_selection: { id: model, params: [{ id: process.argv[5], value: process.argv[6] }] },
      state_file: stateFile,
      id: "live",
      created_at: 0,
    }) + "\n");
  ' "$sess" "$d/repo" "$model" "$sf" "$effort_param" "$effort"

  out=$(FM_CURSOR_STUB_CAPTURE="$capture" node "$bridge_dir/fm-cursor-bridge.mjs" send --session "$sess" --prompt hi)
  [ "$(jget "$out" ok)" = "true" ] || fail "live stub send ok!=true: $out"
  CAPTURE="$capture" MODEL="$model" CWD_EXPECT="$d/repo" EFFORT="$effort" EFFORT_PARAM="$effort_param" node -e '
    const fs = require("node:fs");
    const got = JSON.parse(fs.readFileSync(process.env.CAPTURE, "utf8"));
    if (got.agentId !== "agent-live-stub") throw new Error("agentId " + got.agentId);
    if (got.opts?.model?.id !== process.env.MODEL) throw new Error("model " + JSON.stringify(got.opts?.model));
    const param = got.opts?.model?.params?.[0];
    if (param?.id !== process.env.EFFORT_PARAM || param?.value !== process.env.EFFORT) {
      throw new Error("model params " + JSON.stringify(got.opts?.model?.params));
    }
    if (got.opts?.local?.cwd !== process.env.CWD_EXPECT) throw new Error("cwd " + got.opts?.local?.cwd);
  ' || fail "live SDK resume did not receive model and local cwd"
  assert_grep "working: cursor local turn started" "$sf" "live stub send wrote turn-start status"
  assert_grep "working: cursor turn finished (idle)" "$sf" "live stub send wrote turn-finished status"
  pass "live SDK resume receives the persisted model selection and local cwd"
}

test_live_read_skips_running_conversation() {
  local d; d=$(new_case readrunning); use_case "$d"
  local bridge_dir="$d/bin" sdk_dir="$d/node_modules/@cursor/sdk"
  local sess="$d/running.session.json" marker="$d/conversation.called" out model
  model="cursor-read-model"
  mkdir -p "$bridge_dir" "$sdk_dir"
  cp "$BRIDGE" "$bridge_dir/fm-cursor-bridge.mjs"
  cat > "$sdk_dir/package.json" <<'JSON'
{"type":"module","main":"index.js"}
JSON
  cat > "$sdk_dir/index.js" <<'JS'
import { writeFile } from "node:fs/promises";

export const Agent = {
  async get(agentId) {
    return { agentId, status: "running", archived: false, summary: "active run" };
  },
  async listRuns() {
    return {
      items: [{
        id: "run-active",
        status: "running",
        supports: (op) => op === "conversation",
        async conversation() {
          await writeFile(process.env.FM_CURSOR_STUB_CONVERSATION_CALLED, "called\n");
          throw new Error("conversation should not be called for running runs");
        },
      }],
    };
  },
};
JS
  node -e '
    const fs = require("node:fs");
    const [file, cwd, model] = process.argv.slice(1);
    fs.writeFileSync(file, JSON.stringify({
      schema: "fm-cursor-bridge/session@1",
      agent_id: "agent-read-stub",
      runtime: "local",
      cwd,
      model,
      model_selection: { id: model },
      state_file: "",
      id: "read",
      created_at: 0,
    }) + "\n");
  ' "$sess" "$d/repo" "$model"

  out=$(FM_CURSOR_STUB_CONVERSATION_CALLED="$marker" node "$bridge_dir/fm-cursor-bridge.mjs" read --session "$sess")
  [ "$(jget "$out" ok)" = "true" ] || fail "live running read ok!=true: $out"
  [ "$(jget "$out" status)" = "running" ] || fail "live running read status!=running: $out"
  [ "$(jget "$out" transcript)" = "0" ] || fail "live running read should not collect transcript: $out"
  assert_absent "$marker" "read should not call conversation() for a running run"
  pass "live read skips conversation collection for running runs"
}

test_live_read_uses_newest_listed_run() {
  local d; d=$(new_case readnewest); use_case "$d"
  local bridge_dir="$d/bin" sdk_dir="$d/node_modules/@cursor/sdk"
  local sess="$d/newest.session.json" out model
  model="cursor-read-model"
  mkdir -p "$bridge_dir" "$sdk_dir"
  cp "$BRIDGE" "$bridge_dir/fm-cursor-bridge.mjs"
  cat > "$sdk_dir/package.json" <<'JSON'
{"type":"module","main":"index.js"}
JSON
  cat > "$sdk_dir/index.js" <<'JS'
const turn = (prompt, reply) => ({
  type: "agentConversationTurn",
  turn: {
    userMessage: { text: prompt },
    steps: [{ type: "assistantMessage", message: { text: reply } }],
  },
});

export const Agent = {
  async get(agentId) {
    return { agentId, status: "finished", archived: false, summary: "latest run" };
  },
  async listRuns() {
    return {
      items: [
        {
          id: "run-old",
          status: "finished",
          supports: (op) => op === "conversation",
          conversation: async () => [turn("old prompt", "old reply")],
        },
        {
          id: "run-new",
          status: "finished",
          supports: (op) => op === "conversation",
          conversation: async () => [turn("latest prompt", "latest reply")],
        },
      ],
    };
  },
};
JS
  node -e '
    const fs = require("node:fs");
    const [file, cwd, model] = process.argv.slice(1);
    fs.writeFileSync(file, JSON.stringify({
      schema: "fm-cursor-bridge/session@1",
      agent_id: "agent-read-newest-stub",
      runtime: "local",
      cwd,
      model,
      model_selection: { id: model },
      state_file: "",
      id: "readnewest",
      created_at: 0,
    }) + "\n");
  ' "$sess" "$d/repo" "$model"

  out=$(node "$bridge_dir/fm-cursor-bridge.mjs" read --session "$sess")
  [ "$(jget "$out" ok)" = "true" ] || fail "live newest read ok!=true: $out"
  assert_contains "$out" "latest prompt" "read should collect the newest listed run"
  assert_not_contains "$out" "old prompt" "read should not return the oldest listed run"
  pass "live read uses the newest listed run conversation"
}

# create without a prompt is a usage error in this phase.
test_create_requires_prompt() {
  local d; d=$(new_case noprompt); use_case "$d"
  local sf="$d/state/np.status" sess="$d/np.session.json" out rc
  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" --state-file "$sf" --id np --session-file "$sess" 2>/dev/null); rc=$?
  expect_code 2 "$rc" "create without --prompt exits 2"
  [ "$(jget "$out" ok)" = "false" ] || fail "create-no-prompt ok!=false: $out"
  assert_absent "$sf" "create without prompt writes no status line"
  assert_absent "$sess" "create without prompt writes no session"
  pass "create requires an initial prompt"
}

# cloud runtime is a flag, not a rewrite: the same verbs return the same shapes.
test_cloud_runtime_is_a_flag() {
  local d; d=$(new_case cloud); use_case "$d"
  local sess="$d/c.session.json" out
  out=$(node "$BRIDGE" create --dry-run --runtime cloud --cwd "$d/repo" --id c --session-file "$sess" --prompt hi)
  [ "$(jget "$out" ok)" = "true" ] || fail "cloud create ok!=true: $out"
  [ "$(jget "$out" runtime)" = "cloud" ] || fail "cloud create runtime!=cloud: $out"
  pass "cloud runtime is a flag and reuses the same contract"
}

test_request_event_does_not_override_terminal_status() {
  local d; d=$(new_case requestevent); use_case "$d"
  local sf="$d/state/req.status" sess="$d/req.session.json" out
  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" --state-file "$sf" --id req \
    --prompt "__fm_cursor_fake_request_event__" --session-file "$sess")
  [ "$(jget "$out" ok)" = "true" ] || fail "request-event create ok!=true: $out"
  [ "$(jget "$out" first_run_status)" = "finished" ] || fail "request-event create did not finish: $out"
  assert_no_grep "needs-decision:" "$sf" "request event must not be mapped to needs-decision"
  assert_grep "working: cursor turn finished (idle)" "$sf" "request-event run should still finish idle"
  pass "request events do not override terminal run status"
}

test_kill_cancels_active_run_before_archive() {
  local d; d=$(new_case cancelkill); use_case "$d"
  local sf="$d/state/k.status" sess="$d/k.session.json" out agent_id
  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" --state-file "$sf" --id k \
    --prompt "keep running" --session-file "$sess")
  [ "$(jget "$out" ok)" = "true" ] || fail "active-run setup create ok!=true: $out"
  agent_id=$(jget "$out" agent_id)
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const store = JSON.parse(fs.readFileSync(file, "utf8"));
    store.status = "running";
    fs.writeFileSync(file, JSON.stringify(store) + "\n");
  ' "$d/store/.$agent_id.dryrun.json"
  out=$(node "$BRIDGE" read --dry-run --session "$sess")
  [ "$(jget "$out" status)" = "running" ] || fail "active-run setup should leave a running fake run: $out"
  out=$(node "$BRIDGE" kill --dry-run --session "$sess")
  [ "$(jget "$out" archived)" = "true" ] || fail "kill archived!=true: $out"
  [ "$(jget "$out" deleted)" = "false" ] || fail "kill deleted!=false: $out"
  out=$(node "$BRIDGE" read --dry-run --session "$sess")
  [ "$(jget "$out" status)" = "finished" ] || fail "kill should cancel active run before archive: $out"
  [ "$(jget "$out" archived)" = "true" ] || fail "kill should still archive after cancel: $out"
  pass "kill cancels an active run before archiving"
}

test_live_kill_pages_to_cancel_latest_active_run() {
  local d; d=$(new_case killpages); use_case "$d"
  local bridge_dir="$d/bin" sdk_dir="$d/node_modules/@cursor/sdk"
  local sess="$d/killpages.session.json" cancel_marker="$d/cancelled" archive_marker="$d/archived" list_calls="$d/list-calls.jsonl" out model
  model="cursor-kill-model"
  mkdir -p "$bridge_dir" "$sdk_dir"
  cp "$BRIDGE" "$bridge_dir/fm-cursor-bridge.mjs"
  cat > "$sdk_dir/package.json" <<'JSON'
{"type":"module","main":"index.js"}
JSON
  cat > "$sdk_dir/index.js" <<'JS'
import { appendFile, writeFile } from "node:fs/promises";

const finishedRun = (id) => ({
  id,
  status: "finished",
  supports: (op) => op === "cancel",
  cancel: async () => {
    throw new Error("finished runs must not be cancelled");
  },
});

export const Agent = {
  async listRuns(_agentId, opts) {
    await appendFile(process.env.FM_CURSOR_STUB_LIST_CALLS, JSON.stringify({
      cursor: opts?.cursor ?? "",
      limit: opts?.limit ?? null,
    }) + "\n");
    if (!opts?.cursor) {
      return {
        items: Array.from({ length: 20 }, (_v, i) => finishedRun(`run-${i + 1}`)),
        nextCursor: "page-2",
      };
    }
    if (opts.cursor === "page-2") {
      return {
        items: [
          finishedRun("run-21"),
          {
            id: "run-active-late",
            status: "running",
            supports: (op) => op === "cancel",
            cancel: async () => {
              await writeFile(process.env.FM_CURSOR_STUB_CANCELLED, "cancelled\n");
            },
          },
        ],
      };
    }
    return { items: [] };
  },
  async archive() {
    await writeFile(process.env.FM_CURSOR_STUB_ARCHIVED, "archived\n");
  },
};
JS
  node -e '
    const fs = require("node:fs");
    const [file, cwd, model] = process.argv.slice(1);
    fs.writeFileSync(file, JSON.stringify({
      schema: "fm-cursor-bridge/session@1",
      agent_id: "agent-kill-pages-stub",
      runtime: "local",
      cwd,
      model,
      model_selection: { id: model },
      state_file: "",
      id: "killpages",
      created_at: 0,
    }) + "\n");
  ' "$sess" "$d/repo" "$model"

  out=$(FM_CURSOR_STUB_CANCELLED="$cancel_marker" FM_CURSOR_STUB_ARCHIVED="$archive_marker" \
    FM_CURSOR_STUB_LIST_CALLS="$list_calls" node "$bridge_dir/fm-cursor-bridge.mjs" kill --session "$sess")
  [ "$(jget "$out" ok)" = "true" ] || fail "live paged kill ok!=true: $out"
  [ "$(jget "$out" archived)" = "true" ] || fail "live paged kill archived!=true: $out"
  assert_present "$cancel_marker" "kill should cancel a running run beyond the first page"
  assert_present "$archive_marker" "kill should archive after paged cancellation"
  assert_grep '"cursor":"page-2"' "$list_calls" "kill should request the next run page"
  pass "live kill pages through runs before archiving"
}

test_run_rejection_writes_failed_status() {
  local d; d=$(new_case streamfail); use_case "$d"
  local sf="$d/state/s.status" sess="$d/s.session.json" out rc
  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" --state-file "$sf" --id s \
    --prompt "__fm_cursor_fake_stream_failure__" --session-file "$sess" 2>/dev/null); rc=$?
  expect_code 1 "$rc" "stream failure exits 1"
  [ "$(jget "$out" ok)" = "false" ] || fail "stream failure ok!=false: $out"
  assert_grep "working: cursor local turn started" "$sf" "stream failure wrote turn-start status"
  assert_grep "failed: dry-run stream failure" "$sf" "stream failure wrote failed status"

  d=$(new_case waitfail); use_case "$d"
  sf="$d/state/w.status"; sess="$d/w.session.json"
  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" --state-file "$sf" --id w \
    --prompt "__fm_cursor_fake_wait_failure__" --session-file "$sess" 2>/dev/null); rc=$?
  expect_code 1 "$rc" "wait failure exits 1"
  [ "$(jget "$out" ok)" = "false" ] || fail "wait failure ok!=false: $out"
  assert_grep "working: cursor local turn started" "$sf" "wait failure wrote turn-start status"
  assert_grep "failed: dry-run wait failure" "$sf" "wait failure wrote failed status"
  pass "stream/wait rejections append failed status before returning an error"
}

test_kill_delete_returns_stable_shape() {
  local d; d=$(new_case deletekill); use_case "$d"
  local sf="$d/state/d.status" sess="$d/d.session.json" out
  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" --state-file "$sf" --id d \
    --prompt "delete me" --session-file "$sess")
  [ "$(jget "$out" ok)" = "true" ] || fail "delete setup create ok!=true: $out"
  out=$(node "$BRIDGE" kill --dry-run --session "$sess" --delete)
  [ "$(jget "$out" ok)" = "true" ] || fail "delete kill ok!=true: $out"
  [ "$(jget "$out" archived)" = "false" ] || fail "delete kill archived!=false: $out"
  [ "$(jget "$out" deleted)" = "true" ] || fail "delete kill deleted!=true: $out"
  pass "kill --delete returns the stable kill shape"
}

# --- usage / error contract -------------------------------------------------
test_no_verb_is_usage_error() {
  local out rc
  out=$(node "$BRIDGE" 2>/dev/null); rc=$?
  expect_code 2 "$rc" "no verb exits 2"
  [ "$(jget "$out" ok)" = "false" ] || fail "no verb ok!=false: $out"
  pass "no verb is a usage error (exit 2, ok:false)"
}

test_unknown_verb_is_usage_error() {
  local out rc
  out=$(node "$BRIDGE" frobnicate 2>/dev/null); rc=$?
  expect_code 2 "$rc" "unknown verb exits 2"
  [ "$(jget "$out" ok)" = "false" ] || fail "unknown verb ok!=false: $out"
  pass "unknown verb is a usage error"
}

test_unknown_flag_is_usage_error() {
  local out rc
  out=$(node "$BRIDGE" read --frobble x 2>/dev/null); rc=$?
  expect_code 2 "$rc" "unknown flag exits 2"
  assert_contains "$out" "unknown flag" "unknown flag reported"
  pass "unknown flag is a usage error"
}

test_create_requires_cwd() {
  local out rc
  out=$(node "$BRIDGE" create --dry-run --state-file /tmp/none.status 2>/dev/null); rc=$?
  expect_code 2 "$rc" "create without --cwd exits 2"
  [ "$(jget "$out" ok)" = "false" ] || fail "create-no-cwd ok!=false: $out"
  pass "create requires --cwd"
}

test_local_create_requires_state_file() {
  local d; d=$(new_case needstate); use_case "$d"
  local out rc
  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" 2>/dev/null); rc=$?
  expect_code 2 "$rc" "local create without --state-file exits 2"
  pass "local create requires --state-file"
}

test_send_requires_reattach() {
  local out rc
  out=$(node "$BRIDGE" send --dry-run --prompt hi 2>/dev/null); rc=$?
  expect_code 2 "$rc" "send without reattach target exits 2"
  pass "send requires --session or --agent-id/--cwd"
}

# The live path (no --dry-run) must fail with a clean JSON error, not a crash,
# when @cursor/sdk is not installed. Skip if it somehow IS resolvable so the
# suite never depends on a real key/network.
test_live_path_without_sdk_fails_cleanly() {
  if node -e 'import("@cursor/sdk").then(()=>process.exit(0)).catch(()=>process.exit(3))' 2>/dev/null; then
    pass "live-path missing-sdk assertion skipped (@cursor/sdk is installed)"
    return
  fi
  local d; d=$(new_case livemissing); use_case "$d"
  local out rc
  out=$(node "$BRIDGE" create --cwd "$d/repo" --state-file "$d/state/l.status" --id l --prompt hi 2>/dev/null); rc=$?
  expect_code 1 "$rc" "live path without sdk exits 1"
  [ "$(jget "$out" ok)" = "false" ] || fail "live-path missing sdk ok!=false: $out"
  assert_contains "$out" "@cursor/sdk" "live-path error names the missing dependency"
  pass "live path without @cursor/sdk fails with a clean JSON error"
}

test_help_prints_contract
test_lifecycle_end_to_end
test_reattach_by_agent_id
test_send_resume_preserves_session_model
test_live_resume_forwards_model_to_sdk
test_live_read_skips_running_conversation
test_live_read_uses_newest_listed_run
test_create_requires_prompt
test_cloud_runtime_is_a_flag
test_request_event_does_not_override_terminal_status
test_kill_cancels_active_run_before_archive
test_live_kill_pages_to_cancel_latest_active_run
test_run_rejection_writes_failed_status
test_kill_delete_returns_stable_shape
test_no_verb_is_usage_error
test_unknown_verb_is_usage_error
test_unknown_flag_is_usage_error
test_create_requires_cwd
test_local_create_requires_state_file
test_send_requires_reattach
test_live_path_without_sdk_fails_cleanly

echo "all fm-cursor-bridge tests passed"
