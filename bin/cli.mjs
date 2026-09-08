#!/usr/bin/env node
// Unified CLI for review-pr / verify-bug / evolve.
// Single source of truth — invoked from .command (macOS) and .bat (Windows) wrappers.

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, mkdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROMPTS_DIR = join(SCRIPT_DIR, 'prompts');
const RESULTS_DIR = join(SCRIPT_DIR, 'results');
const API_CONFIG = join(SCRIPT_DIR, '.api-config');

// ── tiny utils ────────────────────────────────────────────

const COMMAND_CACHE = new Map();

/**
 * Windows 上 spawn 無法直接執行 .cmd/.bat（Node 18.20+ 會丟 EINVAL），
 * 因此優先在 PATH 解析出真正的執行檔；只有找不到 .exe 時才退回 shell 模式。
 * @param {string} cmd
 * @returns {{ file: string, shell: boolean }}
 */
function resolveCommand(cmd) {
  if (process.platform !== 'win32') return { file: cmd, shell: false };
  const cached = COMMAND_CACHE.get(cmd);
  if (cached) return cached;
  const dirs = (process.env.PATH || '')
    .split(';')
    .map(d => d.trim().replace(/^"|"$/g, ''))
    .filter(Boolean);
  let resolved = { file: cmd, shell: true };
  outer:
  for (const dir of dirs) {
    for (const ext of ['.exe', '.com', '.bat', '.cmd']) {
      const candidate = join(dir, cmd + ext);
      if (existsSync(candidate)) {
        resolved = { file: candidate, shell: /\.(bat|cmd)$/i.test(ext) };
        break outer;
      }
    }
  }
  COMMAND_CACHE.set(cmd, resolved);
  return resolved;
}

/** shell 模式下 Node 不會替我們跳脫參數，統一加引號避免 cmd.exe 誤判。 */
function quoteArg(arg) {
  return `"${String(arg).replace(/"/g, '""')}"`;
}

function sh(cmd, args, { input, cwd, captureStderr = false } = {}) {
  return new Promise((resolvePromise, reject) => {
    const { file, shell } = resolveCommand(cmd);
    const child = spawn(shell ? quoteArg(file) : file, shell ? args.map(quoteArg) : args, {
      cwd,
      shell,
      stdio: [input != null ? 'pipe' : 'ignore', 'pipe', captureStderr ? 'pipe' : 'inherit'],
    });
    let out = '';
    let err = '';
    child.stdout.on('data', d => (out += d));
    if (captureStderr) child.stderr.on('data', d => (err += d));
    child.on('error', reject);
    child.on('close', code => resolvePromise({ code, stdout: out, stderr: err }));
    if (input != null) {
      child.stdin.end(input);
    }
  });
}

function ask(question, defaultValue = '') {
  return new Promise(resolvePromise => {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, answer => {
      rl.close();
      resolvePromise(answer.trim() || defaultValue);
    });
  });
}

function pause() {
  return new Promise(resolvePromise => {
    process.stdout.write('按任意鍵關閉...');
    process.stdin.setRawMode?.(true);
    process.stdin.resume();
    process.stdin.once('data', () => {
      process.stdin.setRawMode?.(false);
      process.stdin.pause();
      process.stdout.write('\n');
      resolvePromise();
    });
  });
}

function fmtTime(seconds) {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

function fmtNum(n) {
  return Number(n).toLocaleString('en-US');
}

/**
 * 擷取外部指令輸出片段，供錯誤訊息使用（避免整份 log 灌爆終端）。
 * @param {string} text
 * @param {number} max
 * @returns {string}
 */
function excerpt(text, max = 500) {
  const t = String(text || '').trim();
  if (!t) return '';
  return t.length > max ? `${t.slice(0, max)} …（已截斷）` : t;
}

/**
 * 將 stderr 附加到錯誤訊息；沒有內容時回傳空字串。
 * @param {string} stderr
 * @returns {string}
 */
function stderrNote(stderr) {
  const t = excerpt(stderr);
  return t ? `\n   stderr: ${t}` : '';
}

async function withSpinner(label, promise) {
  const chars = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏';
  const start = Date.now();
  let i = 0;
  let done = false;
  const tick = () => {
    if (done) return;
    const elapsed = Math.floor((Date.now() - start) / 1000);
    process.stdout.write(`\r   ⏳ ${label} ${chars[i++ % chars.length]} ${fmtTime(elapsed)} `);
  };
  const timer = setInterval(tick, 100);
  tick();
  try {
    const result = await promise;
    done = true;
    clearInterval(timer);
    const elapsed = Math.floor((Date.now() - start) / 1000);
    process.stdout.write(`\r   ✓ 完成 (${elapsed}s)              \n`);
    return result;
  } catch (e) {
    done = true;
    clearInterval(timer);
    process.stdout.write(`\r${' '.repeat(label.length + 24)}\r`);
    throw e;
  }
}

function tmpFile(ext = '') {
  const dir = mkdtempSync(join(tmpdir(), 'aipr-'));
  return join(dir, `tmp${ext}`);
}

// ── Diff trimming (token 節省) ─────────────────────────────

const MAX_DIFF_LINES = 3000;

// 對 review 無價值、卻大量佔用 token 的檔案：lockfile / 產生檔 / 壓縮檔 / snapshot
const DIFF_EXCLUDE_PATTERNS = [
  /(^|\/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Gemfile\.lock|Cargo\.lock|poetry\.lock|go\.sum)$/,
  /\.min\.(js|css)$/,
  /\.map$/,
  /(^|\/)(dist|build|out|vendor|node_modules|\.next|coverage)\//,
  /(^|\/)__snapshots__\//,
  /\.snap$/,
];

/**
 * 依 `diff --git` 邊界切檔，丟棄無 review 價值的檔案。
 * @param {string} diff
 * @returns {{ diff: string, excluded: string[] }}
 */
function filterDiff(diff) {
  const parts = diff.split(/(?=^diff --git )/m);
  const kept = [];
  const excluded = [];
  for (const part of parts) {
    if (!part.startsWith('diff --git')) {
      if (part) kept.push(part); // 前導內容（通常為空）
      continue;
    }
    const m = part.match(/^diff --git a\/\S+ b\/(\S+)/);
    const path = m ? m[1] : '';
    if (path && DIFF_EXCLUDE_PATTERNS.some(re => re.test(path))) {
      excluded.push(path);
    } else {
      kept.push(part);
    }
  }
  return { diff: kept.join(''), excluded };
}

/**
 * 超大 diff 截斷，避免單次燒掉大量 token。
 * @param {string} diff
 * @param {number} max
 * @returns {{ diff: string, truncated: number }}
 */
function capDiff(diff, max = MAX_DIFF_LINES) {
  const lines = diff.split('\n');
  if (lines.length <= max) return { diff, truncated: 0 };
  return { diff: lines.slice(0, max).join('\n'), truncated: lines.length - max };
}

// ── 推理強度 ──────────────────────────────────────────────

// Claude Code `--effort` 由弱到強。
const EFFORT_LEVELS = ['low', 'medium', 'high', 'xhigh', 'max'];
// opencode `--variant` 的可用值依 provider 而異，這裡只列常見的排序基準；
// 不在清單中的自訂值一律原樣傳給 opencode，不做調整。
const OPENCODE_VARIANT_LEVELS = ['minimal', 'low', 'medium', 'high', 'max'];
// review 預設強度；驗證階段的下限也是同一級，即驗證只升模型、不再往上加碼。
const DEFAULT_EFFORT = 'high';
const VERIFY_MIN_EFFORT = 'high';

/**
 * 把強度補到下限：低於下限則拉到下限，已達或更高則維持原值（不降級）。
 * 不在階梯清單中的自訂值無從比較，原樣返回。
 * @param {string} level
 * @param {string[]} levels 由弱到強的階梯
 * @param {string} floor
 * @returns {string}
 */
function raiseToFloor(level, levels, floor) {
  const current = levels.indexOf(level);
  const min = levels.indexOf(floor);
  if (current < 0 || min < 0) return level;
  return current < min ? floor : level;
}

// ── API config cache ──────────────────────────────────────

function loadApiConfig() {
  const cfg = {
    API_BASE: 'http://localhost:11434/v1',
    API_KEY: '',
    API_MODEL: 'llama3',
    ENGINE: '',
    CLAUDE_EFFORT: DEFAULT_EFFORT,
    OPENCODE_MODEL: '',
    OPENCODE_VARIANT: DEFAULT_EFFORT,
  };
  if (existsSync(API_CONFIG)) {
    for (const line of readFileSync(API_CONFIG, 'utf8').split('\n')) {
      const m = line.match(/^([A-Z_]+)=(.*)$/);
      if (m) cfg[m[1]] = m[2];
    }
  }
  return cfg;
}

function saveApiConfig(cfg) {
  const lines = ['API_BASE', 'API_KEY', 'API_MODEL', 'ENGINE', 'CLAUDE_EFFORT', 'OPENCODE_MODEL', 'OPENCODE_VARIANT']
    .filter(k => cfg[k] !== undefined && cfg[k] !== '')
    .map(k => `${k}=${cfg[k]}`);
  writeFileSync(API_CONFIG, lines.join('\n') + '\n');
}

function maskKey(k) {
  if (!k) return '(none)';
  if (k.length <= 8) return '****';
  return `${k.slice(0, 4)}...${k.slice(-4)}`;
}

async function promptApiSettings() {
  const cfg = loadApiConfig();
  console.log(`   ⚠️  設定會以明文存於 ${API_CONFIG}（已列入 .gitignore），請勿填入不該落地的金鑰`);
  const base = await ask(`API Base URL [${cfg.API_BASE}]: `, cfg.API_BASE);
  const key = await ask(`API Key [${maskKey(cfg.API_KEY)}]: `, cfg.API_KEY);
  const model = await ask(`Model 名稱 [${cfg.API_MODEL}]: `, cfg.API_MODEL);
  const next = { ...cfg, API_BASE: base, API_KEY: key, API_MODEL: model };
  saveApiConfig(next);
  return next;
}

/**
 * 詢問 Claude Code 的 effort（思考深度）。
 * @returns {Promise<{ effort: string }>}
 */
async function promptClaudeSettings() {
  const cfg = loadApiConfig();
  console.log('   （直接 Enter 沿用先前設定）');
  const input = await ask(`思考深度 effort（${EFFORT_LEVELS.join(' / ')}）[${cfg.CLAUDE_EFFORT}]: `, cfg.CLAUDE_EFFORT);
  const picked = input.trim().toLowerCase();
  const effort = EFFORT_LEVELS.includes(picked) ? picked : DEFAULT_EFFORT;
  if (picked !== effort) console.log(`   ⚠️  無效的 effort「${input.trim()}」，改用 ${effort}`);
  saveApiConfig({ ...cfg, CLAUDE_EFFORT: effort });
  return { effort };
}

/**
 * 詢問 opencode 的模型與推理強度；留空則沿用 opencode 自身設定檔預設值。
 * @returns {Promise<{ model: string, variant: string }>}
 */
async function promptOpencodeSettings() {
  const cfg = loadApiConfig();
  console.log('   （直接 Enter 沿用先前設定；模型留空則使用 opencode 設定檔預設值）');
  const model = await ask(`模型 provider/model [${cfg.OPENCODE_MODEL || '(opencode 預設)'}]: `, cfg.OPENCODE_MODEL);
  const input = await ask(`推理強度 variant（${OPENCODE_VARIANT_LEVELS.join(' / ')}）[${cfg.OPENCODE_VARIANT}]: `, cfg.OPENCODE_VARIANT);
  const variant = input.trim().toLowerCase();
  if (variant && !OPENCODE_VARIANT_LEVELS.includes(variant)) {
    console.log(`   ⚠️  「${variant}」不在常見清單中，將原樣傳給 opencode（provider 不支援時會執行失敗）`);
  }
  saveApiConfig({ ...cfg, OPENCODE_MODEL: model, OPENCODE_VARIANT: variant });
  return { model, variant };
}

// ── Engines ───────────────────────────────────────────────
// Each engine returns { text, usage: { input_tokens, output_tokens, cost_usd } }

/**
 * @param {string} model claude 模型別名（sonnet / opus）
 * @param {string} prompt
 * @param {string} [cwd]
 * @param {{ effort?: string }} [options] effort 未提供時不帶 --effort，交由 claude 預設
 * @returns {Promise<{ text: string, usage: { input_tokens: number, output_tokens: number, cost_usd: number } }>}
 */
async function runClaude(model, prompt, cwd, { effort } = {}) {
  const args = ['-p', '--model', model, '--output-format', 'json'];
  if (effort) args.push('--effort', effort);
  const { code, stdout, stderr } = await sh('claude', args, {
    input: prompt,
    cwd,
    captureStderr: true,
  });
  if (code !== 0) {
    throw new Error(`claude 執行失敗（exit ${code}）${stderrNote(stderr)}`);
  }
  let json;
  try {
    json = JSON.parse(stdout);
  } catch {
    throw new Error(`claude 輸出非預期的 JSON：${excerpt(stdout) || '(空輸出)'}${stderrNote(stderr)}`);
  }
  if (json.is_error) {
    throw new Error(`claude 回報錯誤：${excerpt(json.result) || '(無訊息)'}${stderrNote(stderr)}`);
  }
  return {
    text: json.result || '',
    usage: {
      input_tokens: json.usage?.input_tokens || 0,
      output_tokens: json.usage?.output_tokens || 0,
      cost_usd: json.total_cost_usd || 0,
    },
  };
}

/**
 * prompt 以 stdin 餵入（Windows 命令列長度上限約 32KB，diff 很容易超過）。
 * @param {string} prompt
 * @param {string} [cwd]
 * @param {{ model?: string, variant?: string }} [options]
 * @returns {Promise<{ text: string, usage: { input_tokens: number, output_tokens: number, cost_usd: number } }>}
 */
async function runOpencode(prompt, cwd, { model, variant } = {}) {
  const args = ['run', '--format', 'json'];
  if (model) args.push('--model', model);
  if (variant) args.push('--variant', variant);
  const { code, stdout, stderr } = await sh('opencode', args, { input: prompt, cwd, captureStderr: true });
  if (code !== 0) {
    throw new Error(`opencode 執行失敗（exit ${code}）${stderrNote(stderr)}`);
  }
  let text = '';
  let sawEvent = false;
  const usage = { input_tokens: 0, output_tokens: 0, cost_usd: 0 };
  for (const line of stdout.split('\n')) {
    if (!line.trim()) continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    sawEvent = true;
    if (obj.type === 'text') text += obj.part?.text || '';
    // 多步驟 session 會有多個 step_finish，需累計而非只取最後一個
    if (obj.type === 'step_finish') {
      const t = obj.part?.tokens || {};
      usage.input_tokens += t.input || 0;
      usage.output_tokens += t.output || 0;
      usage.cost_usd += obj.part?.cost || 0;
    }
  }
  if (!sawEvent) {
    throw new Error(`opencode 未輸出可解析的 JSON 事件：${excerpt(stdout) || '(空輸出)'}${stderrNote(stderr)}`);
  }
  if (!text.trim()) {
    throw new Error(`opencode 未回傳任何文字內容${stderrNote(stderr)}`);
  }
  return { text, usage };
}

async function runOpenAICompat({ API_BASE, API_KEY, API_MODEL }, prompt) {
  const url = `${API_BASE}/chat/completions`;
  const headers = { 'Content-Type': 'application/json' };
  if (API_KEY) headers.Authorization = `Bearer ${API_KEY}`;
  const res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({ model: API_MODEL, messages: [{ role: 'user', content: prompt }] }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`API ${res.status}: ${body.slice(0, 500)}`);
  }
  const json = await res.json();
  if (json.error?.message) throw new Error(`API 錯誤: ${json.error.message}`);
  return {
    text: json.choices?.[0]?.message?.content || '',
    usage: {
      input_tokens: json.usage?.prompt_tokens || 0,
      output_tokens: json.usage?.completion_tokens || 0,
      cost_usd: 0,
    },
  };
}

// engine: { kind: 'claude-sonnet'|'claude-opus'|'opencode'|'api', api?: {...}, claude?: { effort }, opencode?: { model, variant } }
async function runEngine(engine, prompt, cwd) {
  switch (engine.kind) {
    case 'claude-sonnet': return runClaude('sonnet', prompt, cwd, engine.claude);
    case 'claude-opus':   return runClaude('opus', prompt, cwd, engine.claude);
    case 'opencode':      return runOpencode(prompt, cwd, engine.opencode);
    case 'api':           return runOpenAICompat(engine.api, prompt);
    default: throw new Error(`Unknown engine: ${engine.kind}`);
  }
}

function engineLabel(engine) {
  switch (engine.kind) {
    case 'claude-sonnet':
    case 'claude-opus': {
      const name = engine.kind === 'claude-opus' ? 'Claude Opus' : 'Claude Sonnet';
      const { effort } = engine.claude || {};
      return `${name}${effort ? ` /${effort}` : ''}`;
    }
    case 'opencode': {
      const { model, variant } = engine.opencode || {};
      return `opencode${model ? ` (${model})` : ''}${variant ? ` /${variant}` : ''}`;
    }
    case 'api':           return `API (${engine.api.API_MODEL})`;
  }
}

// pickEngine choices: ordered list of engine kinds available for this command
async function pickEngine(choices, defaultIdx = 1, label = '選擇 AI 引擎') {
  const labels = {
    'claude-sonnet': 'Claude Sonnet',
    'claude-opus':   'Claude Opus',
    'opencode':      'opencode',
    'api':           'OpenAI 相容 API（Ollama / OpenRouter / 其他）',
  };
  console.log('');
  console.log(`🤖 ${label}：`);
  choices.forEach((c, i) => console.log(`  [${i + 1}] ${labels[c]}`));
  console.log('');
  const choice = await ask(`選擇 [1-${choices.length}]（直接 Enter 為 ${defaultIdx}）: `, String(defaultIdx));
  const idx = parseInt(choice, 10);
  const kind = choices[idx - 1] || choices[defaultIdx - 1];
  if (kind === 'api') {
    console.log('');
    const api = await promptApiSettings();
    return { kind, api };
  }
  if (kind === 'opencode') {
    console.log('');
    const opencode = await promptOpencodeSettings();
    return { kind, opencode };
  }
  if (kind.startsWith('claude')) {
    console.log('');
    const claude = await promptClaudeSettings();
    return { kind, claude };
  }
  return { kind };
}

/**
 * 深度驗證要讀原始碼、逐項推理，難度高於 review，因此沿用 review 引擎時升級到較強模型。
 * 目前只有 Claude 有明確的強弱分級；其餘引擎的模型由使用者自行指定，維持原選擇。
 * @param {object} engine
 * @returns {{ engine: object, upgraded: boolean }}
 */
function upgradeForVerify(engine) {
  // Claude：升到 Opus，並把 effort 補到 VERIFY_MIN_EFFORT。
  if (engine.kind.startsWith('claude')) {
    const current = engine.claude?.effort || DEFAULT_EFFORT;
    const effort = raiseToFloor(current, EFFORT_LEVELS, VERIFY_MIN_EFFORT);
    return {
      engine: { ...engine, kind: 'claude-opus', claude: { ...engine.claude, effort } },
      upgraded: engine.kind === 'claude-sonnet' || effort !== current,
    };
  }
  // opencode：模型是任意字串、無從判斷強弱，只把 variant 補到 VERIFY_MIN_EFFORT。
  if (engine.kind === 'opencode') {
    const current = engine.opencode?.variant || DEFAULT_EFFORT;
    const variant = raiseToFloor(current, OPENCODE_VARIANT_LEVELS, VERIFY_MIN_EFFORT);
    return {
      engine: { ...engine, opencode: { ...engine.opencode, variant } },
      upgraded: variant !== current,
    };
  }
  return { engine, upgraded: false };
}

// ── Output formatting helpers ─────────────────────────────

function footerLine(engine, totalSec, usage) {
  return `Model: ${engineLabel(engine)} | Total: ${fmtTime(totalSec)} | Tokens: ${usage.input_tokens} in / ${usage.output_tokens} out | Cost: $${usage.cost_usd.toFixed(4)}`;
}

function printSummaryFooter(engine, totalSec, usage) {
  console.log('');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log(`⏱  總耗時 ${fmtTime(totalSec)}`);
  console.log(`📊 Tokens: ${fmtNum(usage.input_tokens)} in / ${fmtNum(usage.output_tokens)} out | 費用: $${usage.cost_usd.toFixed(4)}`);
}

// ── Command: review ───────────────────────────────────────

async function cmdReview() {
  const totalStart = Date.now();
  console.log('📋 請貼上 PR 連結：');
  const prUrl = await ask('');
  if (!prUrl) {
    console.log('❌ 未輸入 PR 連結');
    return;
  }

  const repoMatch = prUrl.match(/github\.com\/([^/]+\/[^/]+)/);
  const numMatch = prUrl.match(/\/pull\/(\d+)/);
  if (!repoMatch || !numMatch) {
    console.log('❌ 無法解析 PR 連結');
    return;
  }
  const repo = repoMatch[1];
  const prNumber = numMatch[1];

  const cfg = loadApiConfig();
  const cachedIdx = parseInt(cfg.ENGINE || '1', 10);
  const engine = await pickEngine(
    ['claude-sonnet', 'claude-opus', 'opencode', 'api'],
    cachedIdx,
  );
  // Save selected engine index back
  const idxByKind = { 'claude-sonnet': 1, 'claude-opus': 2, 'opencode': 3, 'api': 4 };
  saveApiConfig({ ...loadApiConfig(), ENGINE: String(idxByKind[engine.kind]) });

  console.log(`   → 使用: ${engineLabel(engine)}`);
  console.log('');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('');

  // Fetch PR meta + diff in parallel
  const stepStart = Date.now();
  console.log('📡 [1/3] 取得 PR 資訊 + diff...');
  const metaPromise = sh('gh', ['pr', 'view', prNumber, '--repo', repo, '--json',
    'title,additions,deletions,changedFiles,state,author,baseRefName,headRefName'], { captureStderr: true });
  const diffPromise = sh('gh', ['pr', 'diff', prNumber, '--repo', repo], { captureStderr: true });
  const [metaRes, diffRes] = await Promise.all([metaPromise, diffPromise]);
  if (metaRes.code !== 0) {
    console.log(`❌ 無法取得 PR 資訊: ${metaRes.stderr}`);
    return;
  }
  if (diffRes.code !== 0) {
    console.log(`❌ 無法取得 diff: ${diffRes.stderr}`);
    return;
  }
  const prMeta = JSON.parse(metaRes.stdout);
  const rawDiff = diffRes.stdout;
  console.log(`   ✓ ${prMeta.title}`);
  console.log(`   ✓ ${prMeta.changedFiles} 個檔案 | +${prMeta.additions} -${prMeta.deletions}`);

  // 過濾無價值檔案 + 超大 diff 截斷（節省 token）
  const { diff: filteredDiff, excluded } = filterDiff(rawDiff);
  const { diff: prDiff, truncated } = capDiff(filteredDiff);

  const rawLines = rawDiff.split('\n').length;
  const diffLines = prDiff.split('\n').length;
  console.log(`   ✓ ${diffLines} 行 diff (${Math.floor((Date.now() - stepStart) / 1000)}s)`);
  if (excluded.length) {
    console.log(`   ⏭  已排除 ${excluded.length} 個檔案: ${excluded.slice(0, 5).join(', ')}${excluded.length > 5 ? ' …' : ''}`);
  }
  if (truncated) {
    console.log(`   ✂  diff 過長，已截斷 ${fmtNum(truncated)} 行（原 ${fmtNum(rawLines)} 行）`);
  }
  console.log('');

  // Load detection patterns
  const stepStart2 = Date.now();
  console.log('🔧 [2/3] 準備分析資料...');
  const patterns = readFileSync(join(PROMPTS_DIR, 'patterns.md'), 'utf8');

  let promptTemplate = readFileSync(join(PROMPTS_DIR, 'review-pr.md'), 'utf8');
  promptTemplate = promptTemplate.split('{{PATTERNS}}').join(patterns);

  const notes = [];
  if (excluded.length) {
    notes.push(`已省略 ${excluded.length} 個非程式碼/產生檔（lockfile、min、dist、snapshot 等），不需 review：${excluded.join(', ')}`);
  }
  if (truncated) {
    notes.push(`diff 過長，已截斷末尾 ${truncated} 行，僅就前 ${MAX_DIFF_LINES} 行進行 review。`);
  }
  const notesBlock = notes.length ? `\n## Diff 處理備註\n\n${notes.map(n => `- ${n}`).join('\n')}\n` : '';

  const prompt = `${promptTemplate}
${notesBlock}
## PR Metadata (JSON)
\`\`\`json
${metaRes.stdout.trim()}
\`\`\`

## PR Diff
\`\`\`diff
${prDiff}
\`\`\`
`;
  console.log(`   ✓ 完成 (${Math.floor((Date.now() - stepStart2) / 1000)}s)`);
  console.log('');

  console.log('🤖 [3/3] AI 分析中...');
  const { text, usage } = await withSpinner('分析中', runEngine(engine, prompt));

  const totalSec = Math.floor((Date.now() - totalStart) / 1000);
  const ts = formatTimestamp();
  if (!existsSync(RESULTS_DIR)) mkdirSync(RESULTS_DIR, { recursive: true });
  const outFile = join(RESULTS_DIR, `PR_${prNumber}_${ts}.md`);
  const body = [
    text,
    '',
    '---',
    footerLine(engine, totalSec, usage),
    `<!-- verify-meta: repo=${repo} branch=${prMeta.headRefName} -->`,
    '',
  ].join('\n');
  writeFileSync(outFile, body);

  console.log('');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('');
  // Print 彙整表 onwards
  const idx = text.search(/^#+\s*彙整表/m);
  if (idx >= 0) console.log(text.slice(idx));
  console.log('');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log(`✅ 完整報告已儲存至 ${outFile}`);
  printSummaryFooter(engine, totalSec, usage);

  const bugCount = countBugs(text);
  if (bugCount > 0) {
    console.log('');
    console.log(`🔍 發現 ${bugCount} 個 🔴 BUG 級問題`);
    const verify = (await ask('是否進行深度驗證？ [Y/n]: ', 'Y')).toUpperCase();
    if (verify === 'Y') {
      await cmdVerify(outFile, null, engine);
      return;
    } else {
      console.log(`💡 稍後可執行: ./verify-bug.command ${outFile}`);
    }
  } else {
    console.log('');
    console.log('✅ 沒有 🔴 BUG 級問題');
    const verify = (await ask('是否仍要進行深度驗證？ [y/N]: ', 'N')).toUpperCase();
    if (verify === 'Y') {
      await cmdVerify(outFile, null, engine);
      return;
    }
  }
}

function formatTimestamp() {
  const d = new Date();
  const pad = n => String(n).padStart(2, '0');
  return `${String(d.getFullYear()).slice(-2)}${pad(d.getMonth() + 1)}${pad(d.getDate())}${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

// ── Command: verify ───────────────────────────────────────

function extractBlocks(reportText, emoji) {
  const lines = reportText.split('\n');
  const blocks = [];
  let buf = [];
  const flush = () => { if (buf.length) blocks.push(buf.join('\n')); buf = []; };
  const allEmojis = ['🔴', '🟡', '🟢'];
  const otherEmojis = allEmojis.filter(e => e !== emoji);
  for (const line of lines) {
    if (/^#+\s*(彙整表|判定結果)/.test(line) || /^\*\*(?:彙整表|判定結果)/.test(line)) {
      flush();
      break;
    }
    const isHeading = /^[#*]/.test(line);
    if (isHeading && line.includes(emoji)) {
      flush();
      buf = [line];
      continue;
    }
    if (isHeading && otherEmojis.some(e => line.includes(e))) {
      flush();
      continue;
    }
    if (buf.length) buf.push(line);
  }
  flush();
  return blocks;
}

function extractBugBlocks(reportText) {
  return extractBlocks(reportText, '🔴');
}

function extractWarnBlocks(reportText) {
  return extractBlocks(reportText, '🟡');
}

function titleOf(block) {
  return block.split('\n')[0].replace(/^#+\s*/, '').replace(/\[?[🔴🟡🟢]\]?\s*/g, '').replace(/\*/g, '').trim();
}

/**
 * 統計 🔴 BUG 級問題數量。
 * 優先掃「彙整表」表格列（結構化，較不受排版影響），
 * 其次回退到問題清單區塊數，最後才用「統計」行。
 * @param {string} reportText
 * @returns {number}
 */
function countBugs(reportText) {
  const rows = reportText.split('\n').filter(line =>
    /^\s*\|/.test(line) && /🔴/.test(line) && !/燈號/.test(line) && !/^\s*\|[\s|:-]*$/.test(line));
  if (rows.length) return rows.length;
  const blocks = extractBugBlocks(reportText).length;
  if (blocks) return blocks;
  const statsLine = reportText.split('\n').find(l => /統計/.test(l) && /🔴/.test(l));
  const m = statsLine?.match(/🔴[^/]*?(\d+)/);
  return m ? parseInt(m[1], 10) : 0;
}

// 掃描所有「結論」行，統計各判定數量（支援單次批次驗證多個問題的輸出）。
function countVerdicts(resultText) {
  const counts = { CONFIRMED: 0, FALSE_POSITIVE: 0, POTENTIAL: 0 };
  for (const line of resultText.split('\n')) {
    if (!/結論/.test(line)) continue;
    if (/FALSE\s+POSITIVE/.test(line)) counts.FALSE_POSITIVE++;
    else if (/CONFIRMED/.test(line)) counts.CONFIRMED++;
    else if (/POTENTIAL/.test(line)) counts.POTENTIAL++;
  }
  return counts;
}

async function cmdVerify(reportFileArg, projectDirArg, engineArg) {
  const totalStart = Date.now();
  let reportFile = reportFileArg || process.argv[3];
  if (!reportFile) reportFile = await ask('📋 請輸入 review 報告檔案路徑：');
  if (!reportFile || !existsSync(reportFile)) {
    console.log(`❌ 找不到檔案: ${reportFile}`);
    return;
  }
  const reportText = readFileSync(reportFile, 'utf8');

  // ── 0 BUG 時的 WARN fallback：在 clone 前先判斷，避免無謂的 clone ──
  let blocks = extractBugBlocks(reportText);
  let isWarnFallback = false;
  if (!blocks.length) {
    const warnBlocks = extractWarnBlocks(reportText);
    if (!warnBlocks.length) {
      console.log('   ✅ 沒有找到 🔴 BUG 級問題（也沒有 🟡 WARN）');
      return;
    }
    // 從 review 連續呼叫時（engineArg 已帶入）視為已取得用戶同意，直接 fallback；獨立執行 verify 時才二次確認
    if (engineArg) {
      console.log(`   ℹ️  沒有 🔴 BUG，自動 fallback 至 ${warnBlocks.length} 個 🟡 WARN 進行驗證`);
    } else {
      console.log(`   ℹ️  沒有 🔴 BUG，但發現 ${warnBlocks.length} 個 🟡 WARN`);
      const doWarn = (await ask('是否改為深度驗證 🟡 WARN？ [y/N]: ', 'N')).toUpperCase();
      if (doWarn !== 'Y') {
        console.log('   → 已跳過驗證');
        return;
      }
    }
    blocks = warnBlocks;
    isWarnFallback = true;
  }

  // Resolve project dir: arg > metadata auto-clone > prompt
  let projectDir = projectDirArg || process.argv[4];
  let cloneCleanup = false;
  if (!projectDir) {
    const metaMatch = reportText.match(/<!--\s*verify-meta:\s*repo=(\S+)\s+branch=(\S+?)\s*-->/);
    if (metaMatch) {
      const [, repo, branch] = metaMatch;
      console.log(`📂 從報告取得 repo: ${repo} (${branch})`);
      console.log('   正在 clone...');
      projectDir = mkdtempSync(join(tmpdir(), 'verify-clone-'));
      const { code } = await sh('gh', ['repo', 'clone', repo, projectDir, '--', '--depth', '1', '--branch', branch, '--single-branch']);
      if (code !== 0) {
        console.log('❌ Clone 失敗');
        rmSync(projectDir, { recursive: true, force: true });
        return;
      }
      cloneCleanup = true;
      console.log('   ✓ Clone 完成');
    }
  }
  if (!projectDir) projectDir = await ask('\n📂 請輸入專案路徑（驗證需要讀取原始碼）：');
  if (!projectDir || !existsSync(projectDir) || !statSync(projectDir).isDirectory()) {
    console.log(`❌ 無效的專案路徑: ${projectDir}`);
    return;
  }
  projectDir = resolve(projectDir);
  console.log(`   → 專案: ${projectDir}`);

  // Engine: review 直接傳入時沿用（並升級為更強模型），否則詢問
  let engine = engineArg;
  if (engine) {
    const upgrade = upgradeForVerify(engine);
    console.log('');
    console.log(upgrade.upgraded
      ? `🤖 沿用 review 引擎，並升級為 ${engineLabel(upgrade.engine)}（深度驗證需要更高強度）`
      : `🤖 沿用 review 引擎: ${engineLabel(upgrade.engine)}`);
    engine = upgrade.engine;
  } else {
    engine = await pickEngine(['claude-opus', 'opencode', 'api'], 1, '選擇驗證引擎');
  }
  console.log(`   → 使用: ${engineLabel(engine)}`);
  console.log('');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('');

  const stepStart = Date.now();
  console.log(`🔧 [1/2] 提取 ${isWarnFallback ? '🟡 WARN' : '🔴 BUG'} 級問題...`);
  console.log(`   ✓ 找到 ${blocks.length} 個${isWarnFallback ? ' WARN' : ''} 問題 (${Math.floor((Date.now() - stepStart) / 1000)}s)`);
  console.log('');
  blocks.forEach((b, i) => {
    console.log(`  [${i + 1}] ${titleOf(b)}`);
  });
  console.log('');
  console.log('  [a] 全部驗證');
  console.log('');
  const selection = (await ask('選擇要驗證的問題（數字/a，直接 Enter 為全部）: ', 'a')).toLowerCase();

  console.log('');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('');
  console.log('🤖 [2/2] AI 深度驗證...');
  console.log('');

  const verifyFile = reportFile.replace(/\.md$/, '_verify.md');
  mkdirSync(dirname(verifyFile), { recursive: true });
  let out = isWarnFallback
    ? `## 🔍 WARN 驗證報告（由 BUG fallback）\n\n來源報告: \`${basename(reportFile)}\`\n\n`
    : `## 🔍 BUG 驗證報告\n\n來源報告: \`${basename(reportFile)}\`\n\n`;

  const promptTemplate = readFileSync(join(PROMPTS_DIR, 'verify-bug.md'), 'utf8');

  const selected = blocks
    .map((block, i) => ({ block, i }))
    .filter(({ i }) => selection === 'a' || selection === String(i + 1));

  if (!selected.length) {
    console.log(`   ❌ 無效的選擇: ${selection}`);
    if (cloneCleanup) rmSync(projectDir, { recursive: true, force: true });
    return;
  }

  // 單次批次驗證：所有選定問題合併成一個 prompt，共用 codebase 讀取以節省 token。
  const issuesBlock = selected
    .map(({ block }, n) => `### 問題 ${n + 1}：${titleOf(block)}\n\n${block}`)
    .join('\n\n---\n\n');
  const promptHeader = isWarnFallback
    ? `${promptTemplate}\n\n> 註：原報告無 🔴 BUG，本次為 🟡 WARN fallback 驗證。請以同等嚴謹度判斷每個 WARN 是否實為 BUG / 誤報 / 潛在風險。\n\n## The WARN issues to verify（共 ${selected.length} 個，逐一驗證）\n\n`
    : `${promptTemplate}\n\n## The issues to verify（共 ${selected.length} 個，逐一驗證）\n\n`;
  const prompt = `${promptHeader}${issuesBlock}\n`;

  selected.forEach(({ block }, n) => console.log(`   [${n + 1}/${selected.length}] ${titleOf(block)}`));
  console.log('');
  const { text, usage } = await withSpinner(`驗證 ${selected.length} 個問題`, runEngine(engine, prompt, projectDir));
  console.log('');

  const vc = countVerdicts(text);
  const confirmed = vc.CONFIRMED;
  const falsePositive = vc.FALSE_POSITIVE;
  const potential = vc.POTENTIAL;
  const verified = selected.length;
  const totalUsage = { ...usage };
  out += `${text}\n\n---\n\n`;

  const totalSec = Math.floor((Date.now() - totalStart) / 1000);
  out += [
    '## 📊 驗證摘要',
    '',
    '| 結論 | 數量 |',
    '|------|------|',
    `| 🔴 CONFIRMED（確認是 BUG） | ${confirmed} |`,
    `| ✅ FALSE POSITIVE（誤報） | ${falsePositive} |`,
    `| ⚠️ POTENTIAL（潛在風險） | ${potential} |`,
    `| **合計驗證** | **${verified}** |`,
    '',
    `⏱ 驗證耗時 ${fmtTime(totalSec)}`,
    '',
    '| 項目 | 數值 |',
    '|------|------|',
    `| Input tokens | ${fmtNum(totalUsage.input_tokens)} |`,
    `| Output tokens | ${fmtNum(totalUsage.output_tokens)} |`,
    `| 費用 | $${totalUsage.cost_usd.toFixed(4)} |`,
    '',
    '---',
    footerLine(engine, totalSec, totalUsage),
    '',
  ].join('\n');
  writeFileSync(verifyFile, out);

  if (cloneCleanup) rmSync(projectDir, { recursive: true, force: true });

  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('');
  console.log('📊 驗證結果：');
  console.log(`   🔴 CONFIRMED: ${confirmed}`);
  console.log(`   ✅ FALSE POSITIVE: ${falsePositive}`);
  console.log(`   ⚠️  POTENTIAL: ${potential}`);
  console.log('');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log(`✅ 驗證報告已儲存至 ${verifyFile}`);
  printSummaryFooter(engine, totalSec, totalUsage);
}

// ── main ──────────────────────────────────────────────────

async function main() {
  const cmd = process.argv[2];
  try {
    switch (cmd) {
      case 'review':
        await cmdReview();
        break;
      case 'verify':
        await cmdVerify(process.argv[3], process.argv[4]);
        break;
      default:
        console.error(`Usage: cli.mjs <review|verify> [args...]`);
        process.exit(1);
    }
  } catch (e) {
    console.error('');
    console.error(`❌ ${e.message || e}`);
    if (process.env.DEBUG) console.error(e.stack);
    process.exitCode = 1;
  }
  console.log('');
  await pause();
}

main();
