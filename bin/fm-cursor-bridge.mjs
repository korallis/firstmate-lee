#!/usr/bin/env node
// bin/fm-cursor-bridge.mjs - firstmate <-> Cursor SDK bridge (Track T2).
//
// A shell-callable Node.js ESM sidecar wrapping `@cursor/sdk`, so a Bash
// backend (Track T3, bin/backends/cursor-sdk.sh - NOT this file) can drive a
// Cursor agent through firstmate's session-provider contract: create an
// endpoint, send prompts/steer lines, read live transcript/state, and stop it,
// with the agent's progress landing in `state/<id>.status` (the return channel
// firstmate's watcher requires; see docs/codex-app-backend.md "Backend
// acceptance contract").
//
// ============================================================================
// STABLE SHELL-CALLABLE CONTRACT  (this is what Track T3 codes against)
// ============================================================================
//
// Invocation:  node bin/fm-cursor-bridge.mjs <verb> [flags]
//
// Every verb prints exactly ONE JSON object to stdout and nothing else there
// (diagnostics go to stderr). Every object carries `ok: true|false`. On
// failure the object is `{"ok":false,"error":"<message>","verb":"<verb>"}` and
// the process exits non-zero (2 for usage errors, 1 for runtime failures).
// This "single JSON object on stdout, ok flag, non-zero exit on failure" shape
// is the whole interface; parse stdout as JSON and branch on `ok`.
//
// Runtime is a FLAG, never a rewrite: `--runtime local` (default) or
// `--runtime cloud`. The local runtime is what T3 wires first; the cloud
// runtime reuses the same verbs and the same JSON shapes, differing only in
// which `@cursor/sdk` `Agent.create` key is populated and in that status-file
// writing is a local-runtime responsibility (a cloud agent surfaces through
// the Cursor Agents Window / its own polling, so the bridge does not
// synthesize local status lines for it).
//
// Deterministic offline mode: pass `--dry-run` (or set
// FM_CURSOR_BRIDGE_DRY_RUN=1) to run every verb against a built-in in-repo fake
// SDK with a file-backed store. Dry-run needs no `@cursor/sdk`, no network, and
// no CURSOR_API_KEY, and is what the tests and CI exercise.
//
// ---------------------------------------------------------------------------
// VERBS
// ---------------------------------------------------------------------------
//
// create  Start an agent and run its first turn.
//   Required: --cwd <dir>            Workspace path (Agent.create local.cwd).
//             --state-file <path>    Absolute path to state/<id>.status; the
//                                    return channel the bridge appends to.
//             --prompt <text> | --prompt-file <path>
//                                    Initial prompt for the first turn.
//   Optional: --id <task-id>         Firstmate task id, recorded for tracing.
//             --model <id>           Default "composer-2.5".
//             --effort <value>       Reasoning effort -> model.params entry.
//             --runtime local|cloud  Default "local".
//             --session-file <path>  Where to persist reattach info; default
//                                    "<state-file-dir>/<id-or-agent>.session.json".
//   Prints:  {"ok":true,"agent_id":"agent-...","session_ref":"<path>",
//             "runtime":"local","model":"composer-2.5"}
//   Persists a session JSON at session_ref holding agent_id, runtime, cwd,
//   model, state_file and id - enough for send/read/kill to reattach later.
//
// send    Send a prompt or steer line to an existing agent (a new run).
//   Reattach: --session <path>   (preferred), OR
//             --agent-id <id> --cwd <dir> [--state-file <path>] [--runtime ..].
//   Required: --prompt <text> | --prompt-file <path>.
//   Prints:  {"ok":true,"agent_id":"...","run_id":"...","status":"finished"}
//
// read    Return current transcript/state as JSON (for fm-peek / fm-crew-state).
//   Reattach: --session <path>, OR --agent-id <id> --cwd <dir>.
//   Optional: --limit <n>   Cap transcript turns returned (default 40).
//   Prints:  {"ok":true,"agent_id":"...","runtime":"local","status":"...",
//             "model":"...","summary":"...","last_status_line":"...",
//             "transcript":[{"role":"assistant","text":"..."}, ...]}
//
// kill    Cancel any active run and archive/stop the agent.
//   Reattach: --session <path>, OR --agent-id <id> --cwd <dir>.
//   Optional: --delete   Permanently delete instead of archiving.
//   Prints:  {"ok":true,"agent_id":"...","archived":true,"deleted":false}
//
// --help  Print this contract to stdout and exit 0.
//
// ---------------------------------------------------------------------------
// STATUS RETURN CHANNEL (local runtime)
// ---------------------------------------------------------------------------
//
// While a create/send turn runs in the local runtime, the bridge consumes the
// `@cursor/sdk` event stream and appends firstmate status lines to --state-file,
// mapping SDK run lifecycle to firstmate states (one line at turn start, one at
// turn end - deliberately sparse, since every append wakes firstmate):
//   run started/running      -> "working: cursor <runtime> turn started"
//   run finished             -> "working: cursor turn finished (idle)"
//   run error                -> "failed: <error message>"
// A finished TURN is not the same as a finished TASK: the bridge never
// synthesizes a "done:" line, because task completion is firstmate's judgment
// (via fm-crew-state), not a transport detail. Request events are not mapped
// to firstmate decisions until the bridge has a verified human-input payload
// shape to surface.
//
// STRICT: no TypeScript `any`; precise JSDoc types throughout. No deprecated
// APIs. `@cursor/sdk` is imported lazily and ONLY on the live path, so dry-run
// and tests never require it to be installed.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const DEFAULT_MODEL = 'composer-2.5';
const DEFAULT_EFFORT_PARAM_ID = 'reasoning_effort';
const DEFAULT_TRANSCRIPT_LIMIT = 40;
const SESSION_SCHEMA = 'fm-cursor-bridge/session@1';

/**
 * @typedef {'local'|'cloud'} Runtime
 */

/**
 * Parsed command-line options. All values are strings, booleans, or undefined;
 * no free-form objects, so there is no `any` anywhere in the arg surface.
 * @typedef {object} CliOptions
 * @property {string|undefined} cwd
 * @property {string|undefined} stateFile
 * @property {string|undefined} id
 * @property {string|undefined} prompt
 * @property {string|undefined} promptFile
 * @property {string} model
 * @property {string|undefined} effort
 * @property {string} effortParamId
 * @property {Runtime} runtime
 * @property {string|undefined} sessionFile
 * @property {string|undefined} session
 * @property {string|undefined} agentId
 * @property {boolean} dryRun
 * @property {boolean} deleteAgent
 * @property {number} limit
 */

/**
 * Persisted reattach record written by `create` and consumed by send/read/kill.
 * @typedef {object} SessionRecord
 * @property {string} schema
 * @property {string} agent_id
 * @property {Runtime} runtime
 * @property {string} cwd
 * @property {string} model
 * @property {string} state_file
 * @property {string|undefined} id
 * @property {number} created_at
 */

/**
 * A single reattach target resolved from --session or --agent-id/--cwd.
 * @typedef {object} AgentRef
 * @property {string} agentId
 * @property {Runtime} runtime
 * @property {string} cwd
 * @property {string} model
 * @property {string|undefined} stateFile
 * @property {string|undefined} id
 */

/**
 * A normalized transcript turn returned by `read`.
 * @typedef {object} TranscriptTurn
 * @property {string} role
 * @property {string} text
 */

/**
 * Minimal structural view of the `@cursor/sdk` model selection.
 * @typedef {object} ModelSelection
 * @property {string} id
 * @property {{id:string,value:string}[]=} params
 */

/**
 * The subset of `@cursor/sdk`'s `Run` that this bridge consumes.
 * @typedef {object} SdkRun
 * @property {string} id
 * @property {'running'|'finished'|'error'|'cancelled'} status
 * @property {() => AsyncGenerator<SdkMessage, void>} stream
 * @property {() => Promise<SdkRunResult>} wait
 * @property {() => Promise<void>} cancel
 */

/**
 * The subset of `@cursor/sdk`'s streamed `SDKMessage` events consumed here.
 * @typedef {object} SdkMessage
 * @property {string} type
 * @property {{content?: {type:string,text?:string}[]}=} message
 * @property {string=} text
 * @property {string=} request_id
 */

/**
 * @typedef {object} SdkRunResult
 * @property {string} id
 * @property {'finished'|'error'|'cancelled'} status
 * @property {string=} result
 * @property {{message:string,code?:string}=} error
 */

/**
 * The subset of `@cursor/sdk`'s `SDKAgent` handle consumed here.
 * @typedef {object} SdkAgent
 * @property {string} agentId
 * @property {(message: string) => Promise<SdkRun>} send
 * @property {() => void} close
 */

/**
 * The subset of `@cursor/sdk`'s `SDKAgentInfo` consumed by `read`.
 * @typedef {object} SdkAgentInfo
 * @property {string} agentId
 * @property {string=} summary
 * @property {('running'|'finished'|'error')=} status
 * @property {boolean=} archived
 */

/**
 * The surface of `@cursor/sdk`'s `Agent` namespace this bridge depends on. The
 * live SDK exposes a superset; the fake implements exactly this.
 * @typedef {object} SdkApi
 * @property {(opts: object) => Promise<SdkAgent>} create
 * @property {(agentId: string, opts?: object) => Promise<SdkAgent>} resume
 * @property {(agentId: string, opts?: object) => Promise<SdkAgentInfo>} get
 * @property {(agentId: string, opts?: object) => Promise<TranscriptTurn[]>} conversationOf
 * @property {(agentId: string, opts?: object) => Promise<void>} cancelActiveRuns
 * @property {(agentId: string, opts?: object) => Promise<void>} archive
 * @property {(agentId: string, opts?: object) => Promise<void>} delete
 */

// --- small utilities --------------------------------------------------------

/** Print one JSON object to stdout (the only thing a verb writes there). */
function printJson(/** @type {Record<string, unknown>} */ obj) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

/** A CLI error carrying an intended process exit code. */
class CliError extends Error {
  /** @param {string} message @param {number} code */
  constructor(message, code) {
    super(message);
    this.name = 'CliError';
    /** @type {number} */
    this.code = code;
  }
}

/** @param {string} message @returns {never} */
function usageError(message) {
  throw new CliError(message, 2);
}

/** @param {string} message @returns {never} */
function runtimeError(message) {
  throw new CliError(message, 1);
}

/** @param {unknown} err @returns {string} */
function errorMessage(err) {
  return err instanceof Error ? err.message : String(err);
}

/**
 * Append one firstmate status line to a state file, creating parent dirs.
 * Sparse by design: each append wakes firstmate.
 * @param {string|undefined} stateFile
 * @param {string} line
 */
async function appendStatus(stateFile, line) {
  if (!stateFile) return;
  await fs.mkdir(path.dirname(stateFile), { recursive: true });
  await fs.appendFile(stateFile, `${line}\n`);
}

/**
 * Read the last non-empty line of the state file, or undefined.
 * @param {string|undefined} stateFile
 * @returns {Promise<string|undefined>}
 */
async function lastStatusLine(stateFile) {
  if (!stateFile) return undefined;
  try {
    const text = await fs.readFile(stateFile, 'utf8');
    const lines = text.split('\n').filter((l) => l.trim() !== '');
    return lines.length ? lines[lines.length - 1] : undefined;
  } catch {
    return undefined;
  }
}

// --- argument parsing -------------------------------------------------------

const FLAG_KEYS = new Set(['--dry-run', '--delete', '--help', '-h']);

// Every recognized flag. An unrecognized `--flag` is a usage error so a typo
// never silently changes behavior.
const KNOWN_FLAGS = new Set([
  '--dry-run', '--delete', '--help', '-h',
  '--cwd', '--state-file', '--id', '--prompt', '--prompt-file', '--model',
  '--effort', '--effort-param-id', '--runtime', '--session-file', '--session',
  '--agent-id', '--limit',
]);

/**
 * Parse argv into a verb plus normalized options. Supports `--key value` and
 * bare boolean flags. Unknown flags are a usage error so typos never silently
 * change behavior.
 * @param {string[]} argv
 * @returns {{verb: string, opts: CliOptions}}
 */
function parseArgs(argv) {
  /** @type {Record<string, string|boolean>} */
  const raw = {};
  let verb = '';
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      raw['--help'] = true;
      continue;
    }
    if (arg.startsWith('--')) {
      if (!KNOWN_FLAGS.has(arg)) usageError(`unknown flag: ${arg}`);
      if (FLAG_KEYS.has(arg)) {
        raw[arg] = true;
        continue;
      }
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        usageError(`flag ${arg} needs a value`);
      }
      raw[arg] = next;
      i += 1;
      continue;
    }
    if (verb === '') {
      verb = arg;
      continue;
    }
    usageError(`unexpected argument: ${arg}`);
  }

  const rt = typeof raw['--runtime'] === 'string' ? raw['--runtime'] : 'local';
  if (rt !== 'local' && rt !== 'cloud') {
    usageError(`--runtime must be "local" or "cloud", got "${rt}"`);
  }

  const limitRaw = typeof raw['--limit'] === 'string' ? Number(raw['--limit']) : DEFAULT_TRANSCRIPT_LIMIT;
  if (!Number.isFinite(limitRaw) || limitRaw <= 0) {
    usageError('--limit must be a positive number');
  }

  /** @type {(key: string) => string|undefined} */
  const str = (key) => (typeof raw[key] === 'string' ? /** @type {string} */ (raw[key]) : undefined);

  /** @type {CliOptions} */
  const opts = {
    cwd: str('--cwd'),
    stateFile: str('--state-file'),
    id: str('--id'),
    prompt: str('--prompt'),
    promptFile: str('--prompt-file'),
    model: str('--model') ?? DEFAULT_MODEL,
    effort: str('--effort'),
    effortParamId: str('--effort-param-id') ?? DEFAULT_EFFORT_PARAM_ID,
    runtime: rt,
    sessionFile: str('--session-file'),
    session: str('--session'),
    agentId: str('--agent-id'),
    dryRun: raw['--dry-run'] === true || process.env.FM_CURSOR_BRIDGE_DRY_RUN === '1',
    deleteAgent: raw['--delete'] === true,
    limit: Math.floor(limitRaw),
  };

  if (raw['--help'] === true) verb = '--help';
  return { verb, opts };
}

/**
 * Read the prompt from --prompt or --prompt-file (mutually complementary).
 * @param {CliOptions} opts
 * @returns {Promise<string|undefined>}
 */
async function resolvePrompt(opts) {
  if (opts.prompt !== undefined) return opts.prompt;
  if (opts.promptFile !== undefined) return fs.readFile(opts.promptFile, 'utf8');
  return undefined;
}

/**
 * Build the SDK model selection from --model/--effort.
 * @param {CliOptions} opts
 * @returns {ModelSelection}
 */
function buildModel(opts) {
  /** @type {ModelSelection} */
  const model = { id: opts.model };
  if (opts.effort !== undefined) {
    // Reasoning-effort param ids are model-specific (docs: Cursor.models.list()
    // discovers them); the default id is overridable via --effort-param-id.
    model.params = [{ id: opts.effortParamId, value: opts.effort }];
  }
  return model;
}

// --- session persistence ----------------------------------------------------

/**
 * @param {CliOptions} opts
 * @param {string} agentId
 * @returns {string}
 */
function defaultSessionPath(opts, agentId) {
  if (opts.sessionFile) return path.resolve(opts.sessionFile);
  const base = opts.id ?? agentId;
  const dir = opts.stateFile ? path.dirname(path.resolve(opts.stateFile)) : process.cwd();
  return path.join(dir, `${base}.session.json`);
}

/**
 * @param {string} file
 * @param {SessionRecord} record
 */
async function writeSession(file, record) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, `${JSON.stringify(record, null, 2)}\n`);
}

/**
 * @param {string} file
 * @returns {Promise<SessionRecord>}
 */
async function readSession(file) {
  let text;
  try {
    text = await fs.readFile(file, 'utf8');
  } catch {
    runtimeError(`cannot read session file: ${file}`);
  }
  /** @type {unknown} */
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    runtimeError(`session file is not valid JSON: ${file}`);
  }
  if (typeof parsed !== 'object' || parsed === null) {
    runtimeError(`session file is malformed: ${file}`);
  }
  const rec = /** @type {Partial<SessionRecord>} */ (parsed);
  if (typeof rec.agent_id !== 'string' || (rec.runtime !== 'local' && rec.runtime !== 'cloud')) {
    runtimeError(`session file missing agent_id/runtime: ${file}`);
  }
  return {
    schema: typeof rec.schema === 'string' ? rec.schema : SESSION_SCHEMA,
    agent_id: rec.agent_id,
    runtime: rec.runtime,
    cwd: typeof rec.cwd === 'string' ? rec.cwd : process.cwd(),
    model: typeof rec.model === 'string' ? rec.model : DEFAULT_MODEL,
    state_file: typeof rec.state_file === 'string' ? rec.state_file : '',
    id: typeof rec.id === 'string' ? rec.id : undefined,
    created_at: typeof rec.created_at === 'number' ? rec.created_at : 0,
  };
}

/**
 * Resolve a reattach target from --session (preferred) or --agent-id/--cwd.
 * @param {CliOptions} opts
 * @returns {Promise<AgentRef>}
 */
async function resolveAgentRef(opts) {
  if (opts.session) {
    const rec = await readSession(path.resolve(opts.session));
    return {
      agentId: rec.agent_id,
      runtime: rec.runtime,
      cwd: rec.cwd,
      model: rec.model,
      stateFile: opts.stateFile ?? (rec.state_file || undefined),
      id: rec.id,
    };
  }
  if (opts.agentId) {
    if (!opts.cwd) usageError('--agent-id requires --cwd (local routing)');
    return {
      agentId: opts.agentId,
      runtime: opts.runtime,
      cwd: path.resolve(opts.cwd),
      model: opts.model,
      stateFile: opts.stateFile,
      id: opts.id,
    };
  }
  usageError('need --session <path> or --agent-id <id> --cwd <dir>');
}

// --- SDK loading (live vs. dry-run fake) ------------------------------------

/**
 * Return the SDK facade this bridge drives. In dry-run mode this is the
 * built-in file-backed fake; otherwise it adapts the real `@cursor/sdk`
 * `Agent` namespace to {@link SdkApi}. The real module is imported lazily so
 * dry-run and tests never require it to be installed.
 * @param {CliOptions|AgentRef} opts
 * @param {boolean} dryRun
 * @returns {Promise<SdkApi>}
 */
async function loadSdk(opts, dryRun) {
  if (dryRun) return makeFakeSdk();
  /** @type {{Agent: Record<string, Function>}} */
  let mod;
  try {
    mod = /** @type {{Agent: Record<string, Function>}} */ (await import('@cursor/sdk'));
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    runtimeError(
      `@cursor/sdk could not be loaded (${detail}). Install firstmate's Node dependencies `
        + '(run `npm install` at the repo root), or use --dry-run for offline verification. '
        + 'See docs/cursor-sdk-backend.md.',
    );
  }
  const Agent = mod.Agent;
  const defaultCwd = 'cwd' in opts && opts.cwd ? path.resolve(opts.cwd) : undefined;

  /**
   * Resolve the effective runtime for a call from its routing hint, falling
   * back to the invocation's runtime.
   * @param {{runtime?: Runtime}} [o]
   * @returns {boolean}
   */
  const isCloud = (o) => (o?.runtime ?? opts.runtime) === 'cloud';
  /**
   * @param {{cwd?: string}} [o]
   * @returns {string|undefined}
   */
  const localCwd = (o) => o?.cwd ?? defaultCwd;
  /**
   * Options for get/listRuns/archive/delete: top-level cwd for local routing,
   * empty for cloud (which routes by apiKey from CURSOR_API_KEY).
   * @param {{cwd?: string, runtime?: Runtime}} [o]
   * @returns {{cwd?: string}}
   */
  const opOptions = (o) => (isCloud(o) ? {} : { cwd: localCwd(o) });
  /**
   * Options for resume: cwd is nested under `local` (Partial<AgentOptions>).
   * @param {{cwd?: string, runtime?: Runtime}} [o]
   * @returns {{local?: {cwd?: string}}}
   */
  const resumeOptions = (o) => (isCloud(o) ? {} : { local: { cwd: localCwd(o) } });

  return {
    create: (o) => /** @type {Promise<SdkAgent>} */ (Agent.create(o)),
    resume: (agentId, o) => /** @type {Promise<SdkAgent>} */ (Agent.resume(agentId, resumeOptions(o))),
    get: (agentId, o) => /** @type {Promise<SdkAgentInfo>} */ (Agent.get(agentId, opOptions(o))),
    conversationOf: async (agentId, o) => {
      // Read the most recent run's conversation turns without opening a new
      // agent handle: listRuns is enough, and the run exposes conversation().
      const listOptions = isCloud(o)
        ? { runtime: 'cloud' }
        : { runtime: 'local', cwd: localCwd(o) };
      /** @typedef {{conversation?: () => Promise<unknown[]>, supports?: (op: string) => boolean}} ReadableRun */
      const runs = /** @type {{items?: ReadableRun[]}} */ (await Agent.listRuns(agentId, listOptions));
      const latest = runs.items?.[0];
      if (!latest || typeof latest.conversation !== 'function') return [];
      if (typeof latest.supports === 'function' && !latest.supports('conversation')) return [];
      const turns = /** @type {ConversationTurnLike[]} */ (await latest.conversation());
      return turns.flatMap(normalizeTurn);
    },
    cancelActiveRuns: async (agentId, o) => {
      const listOptions = isCloud(o)
        ? { runtime: 'cloud', limit: 20 }
        : { runtime: 'local', cwd: localCwd(o), limit: 20 };
      /** @typedef {{id?: string, status?: string, supports?: (op: string) => boolean, cancel?: () => Promise<void>}} CancellableRun */
      const runs = /** @type {{items?: CancellableRun[]}} */ (await Agent.listRuns(agentId, listOptions));
      for (const run of runs.items ?? []) {
        if (run.status !== 'running') continue;
        if (typeof run.supports === 'function' && !run.supports('cancel')) {
          runtimeError(`cursor run ${run.id ?? '<unknown>'} cannot be cancelled`);
        }
        if (typeof run.cancel !== 'function') {
          runtimeError(`cursor run ${run.id ?? '<unknown>'} has no cancel operation`);
        }
        await run.cancel();
      }
    },
    archive: (agentId, o) => /** @type {Promise<void>} */ (Agent.archive(agentId, opOptions(o))),
    delete: (agentId, o) => /** @type {Promise<void>} */ (Agent.delete(agentId, opOptions(o))),
  };
}

/**
 * Normalize a live-SDK conversation turn to {@link TranscriptTurn}.
 * @typedef {object} TextBlockLike
 * @property {string=} type
 * @property {string=} text
 *
 * @typedef {object} MessageContentLike
 * @property {TextBlockLike[]=} content
 * @property {string=} text
 *
 * @typedef {object} ConversationStepLike
 * @property {string=} type
 * @property {MessageContentLike=} message
 *
 * @typedef {object} ConversationTurnLike
 * @property {string=} type
 * @property {string=} role
 * @property {string=} text
 * @property {MessageContentLike=} message
 * @property {{userMessage?: {text?: string}, steps?: ConversationStepLike[]}=} turn
 *
 * @param {ConversationTurnLike} turn
 * @returns {TranscriptTurn[]}
 */
function normalizeTurn(turn) {
  if (turn.type === 'agentConversationTurn' && turn.turn) {
    /** @type {TranscriptTurn[]} */
    const transcript = [];
    if (typeof turn.turn.userMessage?.text === 'string' && turn.turn.userMessage.text !== '') {
      transcript.push({ role: 'user', text: turn.turn.userMessage.text });
    }
    for (const step of turn.turn.steps ?? []) {
      if (step.type === 'assistantMessage' && typeof step.message?.text === 'string' && step.message.text !== '') {
        transcript.push({ role: 'assistant', text: step.message.text });
      }
    }
    return transcript;
  }

  const role = turn.role ?? turn.type ?? 'unknown';
  if (turn.message?.content) {
    const text = turn.message.content
      .filter((b) => b.type === 'text' && typeof b.text === 'string')
      .map((b) => b.text ?? '')
      .join('');
    return text === '' ? [] : [{ role, text }];
  }
  return typeof turn.text === 'string' && turn.text !== '' ? [{ role, text: turn.text }] : [];
}

// --- turn execution + status mapping ----------------------------------------

/**
 * Run one turn, streaming events and appending sparse status lines for the
 * local runtime. Returns the terminal run status and final assistant text.
 * @param {SdkAgent} agent
 * @param {string} message
 * @param {AgentRef|CliOptions} ref
 * @returns {Promise<{runId: string, status: string, text: string}>}
 */
async function runTurn(agent, message, ref) {
  const isLocal = ref.runtime === 'local';
  const stateFile = 'stateFile' in ref ? ref.stateFile : undefined;
  const run = await agent.send(message);
  if (isLocal) await appendStatus(stateFile, `working: cursor ${ref.runtime} turn started`);

  let assistantText = '';
  try {
    for await (const ev of run.stream()) {
      if (ev.type === 'assistant' && ev.message?.content) {
        for (const block of ev.message.content) {
          if (block.type === 'text' && typeof block.text === 'string') assistantText += block.text;
        }
      }
    }

    const result = await run.wait();
    if (isLocal) {
      if (result.status === 'error') {
        await appendStatus(stateFile, `failed: ${result.error?.message ?? 'cursor run error'}`);
      } else if (result.status === 'cancelled') {
        await appendStatus(stateFile, 'failed: cursor run cancelled');
      } else if (result.status === 'finished') {
        await appendStatus(stateFile, 'working: cursor turn finished (idle)');
      }
    }
    return { runId: result.id, status: result.status, text: result.result ?? assistantText };
  } catch (err) {
    if (isLocal) await appendStatus(stateFile, `failed: ${errorMessage(err)}`);
    throw err;
  }
}

// --- verb handlers ----------------------------------------------------------

/** @param {CliOptions} opts */
async function cmdCreate(opts) {
  if (!opts.cwd) usageError('create requires --cwd <dir>');
  if (opts.runtime === 'local' && !opts.stateFile) {
    usageError('create --runtime local requires --state-file <path>');
  }
  const prompt = await resolvePrompt(opts);
  if (prompt === undefined) usageError('create requires --prompt <text> or --prompt-file <path>');
  const cwd = path.resolve(opts.cwd);
  const stateFile = opts.stateFile ? path.resolve(opts.stateFile) : undefined;
  const sdk = await loadSdk(opts, opts.dryRun);

  const createOpts = {
    model: buildModel(opts),
    name: opts.id ? `firstmate:${opts.id}` : undefined,
    ...(opts.runtime === 'local' ? { local: { cwd } } : { cloud: {} }),
  };
  const agent = await sdk.create(createOpts);

  /** @type {SessionRecord} */
  const record = {
    schema: SESSION_SCHEMA,
    agent_id: agent.agentId,
    runtime: opts.runtime,
    cwd,
    model: opts.model,
    state_file: stateFile ?? '',
    id: opts.id,
    created_at: Date.now(),
  };
  const sessionFile = defaultSessionPath(opts, agent.agentId);
  await writeSession(sessionFile, record);

  /** @type {AgentRef} */
  const ref = { agentId: agent.agentId, runtime: opts.runtime, cwd, model: opts.model, stateFile, id: opts.id };
  /** @type {{runId:string,status:string}} */
  let firstTurn;
  try {
    const t = await runTurn(agent, prompt, ref);
    firstTurn = { runId: t.runId, status: t.status };
  } finally {
    agent.close();
  }

  printJson({
    ok: true,
    verb: 'create',
    agent_id: agent.agentId,
    session_ref: sessionFile,
    runtime: opts.runtime,
    model: opts.model,
    first_run_id: firstTurn.runId,
    first_run_status: firstTurn.status,
  });
}

/** @param {CliOptions} opts */
async function cmdSend(opts) {
  const prompt = await resolvePrompt(opts);
  if (prompt === undefined) usageError('send requires --prompt <text> or --prompt-file <path>');
  const ref = await resolveAgentRef(opts);
  const sdk = await loadSdk(ref, opts.dryRun);
  const agent = await sdk.resume(ref.agentId, refRouting(ref));

  try {
    const t = await runTurn(agent, prompt, ref);
    printJson({ ok: true, verb: 'send', agent_id: ref.agentId, run_id: t.runId, status: t.status });
  } finally {
    agent.close();
  }
}

/** @param {CliOptions} opts */
async function cmdRead(opts) {
  const ref = await resolveAgentRef(opts);
  const sdk = await loadSdk(ref, opts.dryRun);
  const info = await sdk.get(ref.agentId, refRouting(ref));
  const turns = await sdk.conversationOf(ref.agentId, refRouting(ref));
  const trimmed = turns.slice(-opts.limit);
  const last = await lastStatusLine(ref.stateFile);
  printJson({
    ok: true,
    verb: 'read',
    agent_id: ref.agentId,
    runtime: ref.runtime,
    status: info.status ?? 'unknown',
    archived: info.archived ?? false,
    model: ref.model,
    summary: info.summary ?? '',
    last_status_line: last ?? '',
    transcript: trimmed,
  });
}

/** @param {CliOptions} opts */
async function cmdKill(opts) {
  const ref = await resolveAgentRef(opts);
  const sdk = await loadSdk(ref, opts.dryRun);
  await sdk.cancelActiveRuns(ref.agentId, refRouting(ref));
  if (opts.deleteAgent) {
    await sdk.delete(ref.agentId, refRouting(ref));
    printJson({ ok: true, verb: 'kill', agent_id: ref.agentId, archived: false, deleted: true });
    return;
  }
  await sdk.archive(ref.agentId, refRouting(ref));
  printJson({ ok: true, verb: 'kill', agent_id: ref.agentId, archived: true, deleted: false });
}

/**
 * Routing options for reattach calls (local needs cwd; cloud needs apiKey from env).
 * @param {AgentRef} ref
 * @returns {{cwd?: string, runtime: Runtime}}
 */
function refRouting(ref) {
  return ref.runtime === 'local' ? { cwd: ref.cwd, runtime: 'local' } : { runtime: 'cloud' };
}

function cmdHelp() {
  process.stdout.write(`${HELP_TEXT}\n`);
}

// --- built-in dry-run fake SDK ----------------------------------------------

/**
 * A deterministic, file-backed fake of the {@link SdkApi} surface for offline
 * verification. It persists agent state to a sidecar JSON file keyed by agent
 * id so create/send/read/kill work across separate process invocations exactly
 * as the real durable-agent flow (Agent.resume after a restart) does.
 * @returns {SdkApi}
 */
function makeFakeSdk() {
  let counter = 0;

  /**
   * @typedef {object} FakeStore
   * @property {string} agentId
   * @property {string} model
   * @property {('running'|'finished'|'error')} status
   * @property {boolean} archived
   * @property {ConversationTurnLike[]} transcript
   */

  /** @param {string} agentId */
  const storePath = (agentId) => path.join(process.env.FM_CURSOR_BRIDGE_DRYRUN_DIR ?? process.cwd(), `.${agentId}.dryrun.json`);

  /** @param {string} agentId @returns {Promise<FakeStore>} */
  const load = async (agentId) => {
    const text = await fs.readFile(storePath(agentId), 'utf8').catch(() => '');
    if (!text) runtimeError(`dry-run: unknown agent ${agentId} (no store found)`);
    return /** @type {FakeStore} */ (JSON.parse(text));
  };

  /** @param {FakeStore} store */
  const save = async (store) => {
    await fs.writeFile(storePath(store.agentId), `${JSON.stringify(store)}\n`);
  };

  /** @param {FakeStore} store @returns {TranscriptTurn[]} */
  const transcriptOf = (store) => store.transcript.flatMap(normalizeTurn);

  /**
   * @param {FakeStore} store
   * @param {string} message
   * @returns {SdkRun}
   */
  const makeRun = (store, message) => {
    counter += 1;
    const runId = `run-dry-${counter}`;
    const reply = `dry-run assistant reply to: ${message}`;
    /** @type {SdkMessage[]} */
    const events = [
      { type: 'system' },
      { type: 'user', message: { content: [{ type: 'text', text: message }] } },
      ...(message === '__fm_cursor_fake_request_event__' ? [{ type: 'request', request_id: 'dry-request' }] : []),
      { type: 'assistant', message: { content: [{ type: 'text', text: reply }] } },
    ];
    return {
      id: runId,
      status: 'finished',
      stream: async function* streamEvents() {
        if (message === '__fm_cursor_fake_stream_failure__') {
          throw new Error('dry-run stream failure');
        }
        for (const ev of events) yield ev;
      },
      wait: async () => {
        if (message === '__fm_cursor_fake_wait_failure__') {
          throw new Error('dry-run wait failure');
        }
        store.transcript.push({
          type: 'agentConversationTurn',
          turn: {
            userMessage: { text: message },
            steps: [{ type: 'assistantMessage', message: { text: reply } }],
          },
        });
        store.status = 'finished';
        await save(store);
        return { id: runId, status: 'finished', result: reply };
      },
      cancel: async () => {
        store.status = 'finished';
        await save(store);
      },
    };
  };

  /** @param {FakeStore} store @returns {SdkAgent} */
  const makeAgent = (store) => ({
    agentId: store.agentId,
    send: async (message) => makeRun(store, message),
    close: () => {},
  });

  return {
    create: async () => {
      counter += 1;
      const agentId = `agent-dry-${process.pid}-${counter}`;
      /** @type {FakeStore} */
      const store = { agentId, model: DEFAULT_MODEL, status: 'running', archived: false, transcript: [] };
      await save(store);
      return makeAgent(store);
    },
    resume: async (agentId) => makeAgent(await load(agentId)),
    get: async (agentId) => {
      const store = await load(agentId);
      const transcript = transcriptOf(store);
      return {
        agentId,
        summary: transcript.length ? transcript[transcript.length - 1].text : '',
        status: store.status,
        archived: store.archived,
      };
    },
    conversationOf: async (agentId) => transcriptOf(await load(agentId)),
    cancelActiveRuns: async (agentId) => {
      const store = await load(agentId);
      if (store.status === 'running') {
        store.status = 'finished';
        await save(store);
      }
    },
    archive: async (agentId) => {
      const store = await load(agentId);
      store.archived = true;
      await save(store);
    },
    delete: async (agentId) => {
      await fs.rm(storePath(agentId), { force: true });
    },
  };
}

// --- entry point ------------------------------------------------------------

const HELP_TEXT = extractHeaderContract();

/**
 * Extract the documented contract block from this file's own header comment so
 * `--help` and the source never drift.
 * @returns {string}
 */
function extractHeaderContract() {
  return [
    'fm-cursor-bridge.mjs - firstmate <-> Cursor SDK bridge',
    '',
    'Usage: node bin/fm-cursor-bridge.mjs <verb> [flags]',
    '',
    'Verbs:',
    '  create  Start an agent. Required: --cwd <dir>; --state-file <path> for',
    '          --runtime local; --prompt/--prompt-file. Optional: --id, --model',
    `          (default ${DEFAULT_MODEL}), --effort, --runtime local|cloud,`,
    '          --session-file. Prints {agent_id, session_ref}.',
    '  send    Send a prompt/steer line. Reattach via --session <path> or',
    '          --agent-id <id> --cwd <dir>. Required: --prompt/--prompt-file.',
    '          Prints {ok, agent_id, run_id, status}.',
    '  read    Return transcript/state as JSON (for fm-peek/fm-crew-state).',
    '          Reattach via --session or --agent-id --cwd. Optional --limit.',
    '  kill    Cancel/archive the agent (--delete to remove permanently).',
    '',
    'Global:',
    '  --dry-run            Offline deterministic fake SDK (no @cursor/sdk, no',
    '                       network, no CURSOR_API_KEY). Also FM_CURSOR_BRIDGE_DRY_RUN=1.',
    '  --runtime local|cloud  Runtime is a flag, not a rewrite (default local).',
    '  --help               Print this contract.',
    '',
    'Contract: each verb prints exactly one JSON object to stdout with an `ok`',
    'boolean; failures print {"ok":false,"error":...} and exit non-zero (2 usage,',
    '1 runtime). In the local runtime the bridge appends firstmate status lines',
    'to --state-file from the SDK event stream. See the file header and',
    'docs/cursor-sdk-backend.md for the full contract.',
  ].join('\n');
}

/** @param {string} verb @param {CliOptions} opts */
async function dispatch(verb, opts) {
  switch (verb) {
    case 'create':
      return cmdCreate(opts);
    case 'send':
      return cmdSend(opts);
    case 'read':
      return cmdRead(opts);
    case 'kill':
      return cmdKill(opts);
    case '--help':
    case 'help':
      cmdHelp();
      return undefined;
    case '':
      usageError('no verb given (expected create|send|read|kill|--help)');
      return undefined;
    default:
      usageError(`unknown verb: ${verb} (expected create|send|read|kill|--help)`);
      return undefined;
  }
}

async function main() {
  /** @type {string} */
  let verb = '';
  try {
    const parsed = parseArgs(process.argv.slice(2));
    verb = parsed.verb;
    await dispatch(verb, parsed.opts);
  } catch (err) {
    const code = err instanceof CliError ? err.code : 1;
    const message = errorMessage(err);
    printJson({ ok: false, verb: verb || undefined, error: message });
    process.exitCode = code;
  }
}

main();
