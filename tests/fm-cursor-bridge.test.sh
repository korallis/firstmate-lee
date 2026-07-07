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

# create without a prompt starts the agent but runs no turn (no status lines).
test_create_without_prompt_runs_no_turn() {
  local d; d=$(new_case noprompt); use_case "$d"
  local sf="$d/state/np.status" out
  out=$(node "$BRIDGE" create --dry-run --cwd "$d/repo" --state-file "$sf" --id np)
  [ "$(jget "$out" ok)" = "true" ] || fail "create-no-prompt ok!=true: $out"
  [ -z "$(jget "$out" first_run_id)" ] || fail "create-no-prompt should not run a turn: $out"
  assert_absent "$sf" "create with no prompt writes no status line"
  pass "create without a prompt runs no turn and writes no status"
}

# cloud runtime is a flag, not a rewrite: the same verbs return the same shapes.
test_cloud_runtime_is_a_flag() {
  local d; d=$(new_case cloud); use_case "$d"
  local sess="$d/c.session.json" out
  out=$(node "$BRIDGE" create --dry-run --runtime cloud --cwd "$d/repo" --id c --session-file "$sess")
  [ "$(jget "$out" ok)" = "true" ] || fail "cloud create ok!=true: $out"
  [ "$(jget "$out" runtime)" = "cloud" ] || fail "cloud create runtime!=cloud: $out"
  pass "cloud runtime is a flag and reuses the same contract"
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
test_create_without_prompt_runs_no_turn
test_cloud_runtime_is_a_flag
test_no_verb_is_usage_error
test_unknown_verb_is_usage_error
test_unknown_flag_is_usage_error
test_create_requires_cwd
test_local_create_requires_state_file
test_send_requires_reattach
test_live_path_without_sdk_fails_cleanly

echo "all fm-cursor-bridge tests passed"
