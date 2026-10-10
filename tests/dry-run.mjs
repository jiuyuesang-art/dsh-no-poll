// Offline dry-run tests for the dsh-no-poll plugin.
// Verifies plugin behaviour without installing it into DSH.
//
// Run: node tests/dry-run.mjs
import { pathToFileURL, fileURLToPath } from 'node:url'
import path from 'node:path'

const here = path.dirname(fileURLToPath(import.meta.url))
const pluginPath = path.join(here, '..', 'plugin', 'no-poll.js')
const mod = await import(pathToFileURL(pluginPath).href)

let pass = 0
let fail = 0
function check(label, ok, extra = '') {
  console.log(`  ${ok ? 'PASS' : 'FAIL'} ${label}${extra ? '  ' + extra : ''}`)
  if (ok) pass++
  else fail++
}

console.log(`  exports: ${Object.keys(mod).sort().join(', ')}`)

// ---------------------------------------------------------------- exports ---
check('exports name', mod.name === 'no-poll', `name=${mod.name}`)
check('exports inject containing systemPrompt',
  Array.isArray(mod.inject) && mod.inject.includes('systemPrompt'),
  JSON.stringify(mod.inject))
check('exports apply as a function', typeof mod.apply === 'function')
check('exports renderRule for testing', typeof mod.renderRule === 'function')

// ------------------------------------------------------------------ rule ----
console.log('\n  -- rule text --')
const rule = mod.renderRule({})
const required = [
  ['names the anti-polling rule', /do NOT repeatedly call tools/i],
  ['explains the host wakes you', /host wakes you/i],
  ['gives the four steps', /Submit the task[\s\S]*background job[\s\S]*END YOUR TURN[\s\S]*wakes you/i],
  ['rule 1: no timeout', /NO TIMEOUT/i],
  ['rule 1: timeout is not a failure verdict', /timeout is NOT a failure\s+verdict|timeout is NOT a failure verdict/i],
  ['rule 2: silence is normal', /SILENCE MEANS IT IS WORKING/i],
  ['rule 2: do not kill the task', /job status[\s\S]*job cancel/i],
  ['rule 3: both outcomes wake you', /BOTH SUCCESS AND FAILURE WAKE YOU/i],
  ['rule 3: last-line format', /DONE\\t[\s\S]*FAILED\\t/],
  ['CLI programs need no waiter', /need NO waiter/i],
  ['mentions the directed client id', /client[ _-]id/i],
  ['points at the waiters directory', /waiters/],
  ['lists the four subcommands', /comfyui[\s\S]*http[\s\S]*file[\s\S]*probe/],
  ['points at the adaptation guide', /add-your-own/],
]
for (const [label, re] of required) check(label, re.test(rule))

const pathMatch = rule.match(/live in: `([^`]+waiters)`/)
check('injected path is absolute',
  !!pathMatch && /^[A-Za-z]:[\\/]|^\//.test(pathMatch[1]),
  pathMatch ? pathMatch[1] : '(no match)')

// The rule is paid for on every single turn, so its size is part of the contract.
// Token estimate must account for script: CJK runs roughly 1.5 chars/token while
// Latin text runs roughly 4 chars/token. A single chars/N divisor is badly wrong
// for mixed text.
const chars = rule.length
const cjkChars = (rule.match(/[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uff00-\uffef]/g) || []).length
const latinChars = chars - cjkChars
const estimatedTokens = Math.round(cjkChars / 1.5 + latinChars / 4)
check('stays compact (<= 800 tokens)', estimatedTokens <= 800,
  `${chars} chars (${cjkChars} CJK + ${latinChars} other), ~${estimatedTokens} tokens/turn`)

const shortRule = mod.renderRule({ verbose: false })
check('verbose=false is much shorter', shortRule.length < chars * 0.5, `${shortRule.length} chars`)

const withExtra = mod.renderRule({ extraLines: ['ComfyUI runs at 127.0.0.1:8188'] })
check('extraLines are appended', withExtra.includes('ComfyUI runs at 127.0.0.1:8188'))

check('rule contains no CJK (English-only contract)',
  !/[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uff00-\uffef]/.test(rule))

// ------------------------------------------------------------------ apply ---
console.log('\n  -- apply (fake ctx) --')
function fakeCtx() {
  const registered = []
  return {
    registered,
    systemPrompt: { section: (section) => { registered.push(section); return () => {} } },
  }
}

{
  const ctx = fakeCtx()
  mod.apply(ctx, {})
  check('registers exactly one section', ctx.registered.length === 1, `count=${ctx.registered.length}`)
  const section = ctx.registered[0]
  check('section has a name', typeof section?.name === 'string' && section.name.length > 0, `name=${section?.name}`)
  check('section order is a finite number', Number.isFinite(section?.order), `order=${section?.order}`)
  check('section text is non-empty', typeof section?.text === 'string' && section.text.length > 0)
}

{
  const ctx = fakeCtx()
  mod.apply(ctx, { enabled: false })
  check('enabled=false registers nothing', ctx.registered.length === 0)
}

{
  const ctx = fakeCtx()
  mod.apply(ctx, { order: 500 })
  check('custom order is honoured', ctx.registered[0]?.order === 500, `order=${ctx.registered[0]?.order}`)
}

{
  const ctx = fakeCtx()
  mod.apply(ctx, { order: Number.NaN })
  check('non-finite order falls back (no throw)', Number.isFinite(ctx.registered[0]?.order),
    `order=${ctx.registered[0]?.order}`)
}

{
  const ctx = fakeCtx()
  mod.apply(ctx, { sectionName: 'my-rule' })
  check('custom sectionName is honoured', ctx.registered[0]?.name === 'my-rule')
}

// Fail-safe: a broken context must never propagate an exception into the session.
{
  let threw = false
  try { mod.apply({}, {}) } catch { threw = true }
  check('incomplete ctx does not throw (fail-safe)', !threw)
}
{
  let threw = false
  try { mod.apply({ systemPrompt: { section: () => { throw new Error('boom') } } }, {}) } catch { threw = true }
  check('throwing section() is swallowed (fail-safe)', !threw)
}

console.log(`\n  result: ${pass} passed / ${fail} failed`)
process.exit(fail ? 1 : 0)
