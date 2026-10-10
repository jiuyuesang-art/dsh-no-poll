// dsh-no-poll -- stop the model from polling long tasks.
//
// WHAT IT DOES
//   Registers one small, permanent section in the system prompt of every session,
//   telling the model: for long tasks, do not wait by repeatedly asking "is it done
//   yet?" -- hand the wait to a background process and let the host wake you.
//
// WHY A PLUGIN
//   "Do not poll" needs no code by itself -- it needs the MODEL TO KNOW IT.
//   Putting the rule in a skill only applies when that skill is loaded. Putting it
//   in a preset persona only applies inside that preset. This plugin registers a
//   section on the systemPrompt service, so the rule holds in every session of
//   every preset. That is the whole point: it is orthogonal to presets.
//
// MOUNT POINT (verified against the shipped DSH)
//   service key : 'systemPrompt'       (inject: ['systemPrompt'])
//   register    : ctx.systemPrompt.section({ name, order, text })
//   order scale : SECTION_ORDERS in @deepseek-ai/dsh-system-prompt
//                 HARNESS_IDENTITY = -1000, DEPLOYMENT_PERSONA_PREFIX = 0,
//                 PLAN_POLICY = 500, TEAM_POLICY = 600, MCP_SERVERS = 3100
//
// THREE RULES FOR THIS FILE
//   1. Fail-safe. Any error must leave the session untouched. If registration
//      fails, behave as if the plugin were not installed.
//   2. Stay small. This text is paid for on EVERY turn. Keep it to the essentials.
//   3. Switchable. config.enabled = false registers nothing.

export const name = 'no-poll'

export const inject = ['systemPrompt']

export const DEFAULTS = {
  enabled: true,
  // Registered section identity and position. Default sits right after the persona
  // and before the policy sections, so it reads as a behavioural rule.
  sectionName: 'no-poll',
  order: 100,
  // Extra lines appended to the rule. Empty array appends nothing.
  extraLines: [],
  // When false, emit a minimal version (core lines only).
  verbose: true,
}

/** Root directory of this package, as a plain path. Used to point the model at the
 *  bundled waiters. Computed from this module's own URL so the injected rule can
 *  carry a real absolute path instead of a placeholder. */
function packageRoot() {
  try {
    const here = new URL('.', import.meta.url)
    return new URL('../', here).href.replace(/\/$/, '')
  } catch {
    return ''
  }
}

/** Build the injected text. Exported so it can be tested offline. */
export function renderRule(config = {}) {
  const cfg = { ...DEFAULTS, ...config }
  const root = packageRoot()
  // file:///C:/... -> C:/... so the path is usable as typed.
  const dir = root
    ? decodeURIComponent(root.replace(/^file:\/\/\//, '').replace(/^file:\/\//, ''))
    : ''
  const waitDir = dir ? `${dir}/waiters` : '<dsh-no-poll>/waiters'

  if (!cfg.verbose) {
    return [
      '[Long tasks: do not poll]',
      'For anything longer than about a minute, do not repeatedly call tools to ask "is it done yet?"',
      'Hand the wait to a background job; the host wakes you when it finishes.',
      `Ready-made waiters: \`${waitDir}\` (wait.py / wait.ps1 / wait.sh).`,
    ].join('\n')
  }

  const lines = [
    '[Long tasks: do not poll -- let the host wake you]',
    '',
    'For anything longer than about a minute, do NOT repeatedly call tools to ask',
    '"is it done yet?". Every ask costs a full round trip plus context, and the task',
    'does not finish any sooner. Instead:',
    '',
    '1. Submit the task, take its id, and RETURN IMMEDIATELY (do not block on submit).',
    '2. Start a waiter as a background job (`run_in_background` in DSH).',
    '3. END YOUR TURN. Really stop -- do not rephrase the same question.',
    '4. The host wakes you when the job exits. Read the last line to see the outcome.',
    '',
    'THREE RULES. Breaking any one of them makes the whole mechanism pointless.',
    '',
    '1. NO TIMEOUT. The waiters have none, and that is deliberate. Queued, slow, and',
    '   apparently stuck tasks are all still waited on. A timeout is NOT a failure',
    '   verdict; guessing with one only produces false negatives.',
    '',
    '2. SILENCE MEANS IT IS WORKING. Never call `job status` / `job cancel`, and never',
    '   send an interrupt upstream, just to "check" on the task -- that is exactly what',
    '   kills it. You WILL be notified when the task ends, whether it succeeded or failed.',
    '',
    '3. BOTH SUCCESS AND FAILURE WAKE YOU. The host notifies on job exit, regardless of',
    '   exit code, so both are terminal states. Read the last line:',
    '   `DONE\\t...` success, continue. `FAILED\\t...` the system reported a failure --',
    '   diagnose it, do not blindly retry.',
    '',
    `Waiters (\`wait.py\` / \`wait.ps1\` / \`wait.sh\`, identical interface) live in: \`${waitDir}\``,
    'Subcommands: `comfyui`, `http`, `file`, `probe`.',
    '- ComfyUI needs BOTH `--prompt-id` and `--client-id`: its execution events are sent',
    '  DIRECTED at the submitting client, so without the client id you get a clean',
    '  handshake and zero events.',
    '- Plain command-line programs (`ffmpeg`, `blender -b`) need NO waiter -- just run',
    '  them with `run_in_background`.',
    '- Adapting your own software: `examples/add-your-own.md`.',
  ]
  if (Array.isArray(cfg.extraLines) && cfg.extraLines.length) {
    lines.push('', ...cfg.extraLines.map((line) => String(line)))
  }
  return lines.join('\n')
}

export function apply(ctx, config) {
  // Wrapped end to end: a failure to register must never affect the session.
  try {
    const cfg = { ...DEFAULTS, ...(config || {}) }
    if (!cfg.enabled) return

    const text = renderRule(cfg)
    if (!text.trim()) return

    // `order` must be a finite number; section() throws otherwise.
    const order = Number.isFinite(Number(cfg.order)) ? Number(cfg.order) : DEFAULTS.order

    ctx.systemPrompt.section({
      name: String(cfg.sectionName || DEFAULTS.sectionName),
      order,
      text,
    })
  } catch {
    // Registration failed. Silently do nothing: without this rule the model simply
    // keeps its previous behaviour, and nothing else is disturbed.
  }
}
