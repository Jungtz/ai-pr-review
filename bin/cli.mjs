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

function sh(cmd, args, { input, cwd, captureStderr = false } = {}) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(cmd, args, {
      cwd,
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
    process.stdout.write('\r');
    throw e;
  }
}

function tmpFile(ext = '') {
  const dir = mkdtempSync(join(tmpdir(), 'aipr-'));
  return join(dir, `tmp${ext}`);
}

// ── API config cache ──────────────────────────────────────

function loadApiConfig() {
  const cfg = { API_BASE: 'http://localhost:11434/v1', API_KEY: '', API_MODEL: 'llama3', ENGINE: '' };
  if (existsSync(API_CONFIG)) {
    for (const line of readFileSync(API_CONFIG, 'utf8').split('\n')) {
      const m = line.match(/^([A-Z_]+)=(.*)$/);
      if (m) cfg[m[1]] = m[2];
    }
  }
  return cfg;
}

function saveApiConfig(cfg) {
  const lines = ['API_BASE', 'API_KEY', 'API_MODEL', 'ENGINE']
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
  const base = await ask(`API Base URL [${cfg.API_BASE}]: `, cfg.API_BASE);
  const key = await ask(`API Key [${maskKey(cfg.API_KEY)}]: `, cfg.API_KEY);
  const model = await ask(`Model 名稱 [${cfg.API_MODEL}]: `, cfg.API_MODEL);
  const next = { ...cfg, API_BASE: base, API_KEY: key, API_MODEL: model };
  saveApiConfig(next);
  return next;
}

// ── Engines ───────────────────────────────────────────────
// Each engine returns { text, usage: { input_tokens, output_tokens, cost_usd } }

async function runClaude(model, prompt, cwd) {
  const { stdout } = await sh('claude', ['-p', '--model', model, '--output-format', 'json'], {
    input: prompt,
    cwd,
    captureStderr: true,
  });
  const json = JSON.parse(stdout);
  return {
    text: json.result || '',
    usage: {
      input_tokens: json.usage?.input_tokens || 0,
      output_tokens: json.usage?.output_tokens || 0,
      cost_usd: json.total_cost_usd || 0,
    },
  };
}

async function runOpencode(prompt, cwd) {
  const { stdout } = await sh('opencode', ['run', '--format', 'json', prompt], { cwd });
  const lines = stdout.split('\n').filter(Boolean);
  let text = '';
  let lastStep = null;
  for (const line of lines) {
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    if (obj.type === 'text') text += obj.part?.text || '';
    if (obj.type === 'step_finish') lastStep = obj.part;
  }
  const t = lastStep?.tokens || {};
  return {
    text,
    usage: {
      input_tokens: t.input || 0,
      output_tokens: t.output || 0,
      cost_usd: lastStep?.cost || 0,
    },
  };
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

// engine: { kind: 'claude-sonnet'|'claude-opus'|'opencode'|'api', api?: {...} }
async function runEngine(engine, prompt, cwd) {
  switch (engine.kind) {
    case 'claude-sonnet': return runClaude('sonnet', prompt, cwd);
    case 'claude-opus':   return runClaude('opus', prompt, cwd);
    case 'opencode':      return runOpencode(prompt, cwd);
    case 'api':           return runOpenAICompat(engine.api, prompt);
    default: throw new Error(`Unknown engine: ${engine.kind}`);
  }
}

function engineLabel(engine) {
  switch (engine.kind) {
    case 'claude-sonnet': return 'Claude Sonnet';
    case 'claude-opus':   return 'Claude Opus';
    case 'opencode':      return 'opencode';
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
  return { kind };
}

// Honor PR_REVIEW_ENGINE env from review → verify chain.
function inheritEngine() {
  const env = process.env.PR_REVIEW_ENGINE;
  if (!env) return null;
  if (env === 'claude') return { kind: 'claude-opus' };
  if (env === 'opencode') return { kind: 'opencode' };
  if (env === 'api' && process.env.API_BASE && process.env.API_MODEL) {
    return {
      kind: 'api',
      api: {
        API_BASE: process.env.API_BASE,
        API_KEY: process.env.API_KEY || '',
        API_MODEL: process.env.API_MODEL,
      },
    };
  }
  return null;
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
  const prDiff = diffRes.stdout;
  console.log(`   ✓ ${prMeta.title}`);
  console.log(`   ✓ ${prMeta.changedFiles} 個檔案 | +${prMeta.additions} -${prMeta.deletions}`);
  const diffLines = prDiff.split('\n').length;
  console.log(`   ✓ ${diffLines} 行 diff (${Math.floor((Date.now() - stepStart) / 1000)}s)`);
  console.log('');

  // Load detection patterns
  const stepStart2 = Date.now();
  console.log('🔧 [2/3] 準備分析資料...');
  const patterns = readFileSync(join(PROMPTS_DIR, 'patterns.md'), 'utf8');

  let promptTemplate = readFileSync(join(PROMPTS_DIR, 'review-pr.md'), 'utf8');
  promptTemplate = promptTemplate.split('{{PATTERNS}}').join(patterns);
  const prompt = `${promptTemplate}

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

  // Detect 🔴 BUG count from 統計 section
  const statsLine = text.split('\n').find(l => /統計/.test(l) && /🔴/.test(l));
  let bugCount = 0;
  if (statsLine) {
    const m = statsLine.match(/🔴[^/]*?(\d+)/);
    if (m) bugCount = parseInt(m[1], 10);
  }
  if (bugCount > 0) {
    console.log('');
    console.log(`🔍 發現 ${bugCount} 個 🔴 BUG 級問題`);
    const verify = (await ask('是否進行深度驗證？ [Y/n]: ', 'Y')).toUpperCase();
    if (verify === 'Y') {
      // Pass engine via env to verify subcommand
      process.env.PR_REVIEW_ENGINE = engine.kind === 'api' ? 'api'
        : engine.kind.startsWith('claude') ? 'claude' : 'opencode';
      if (engine.kind === 'api') {
        process.env.API_BASE = engine.api.API_BASE;
        process.env.API_KEY = engine.api.API_KEY;
        process.env.API_MODEL = engine.api.API_MODEL;
      }
      await cmdVerify(outFile);
      return;
    } else {
      console.log(`💡 稍後可執行: ./verify-bug.command ${outFile}`);
    }
  } else {
    console.log('');
    console.log('✅ 沒有 🔴 BUG 級問題');
  }
}

function formatTimestamp() {
  const d = new Date();
  const pad = n => String(n).padStart(2, '0');
  return `${String(d.getFullYear()).slice(-2)}${pad(d.getMonth() + 1)}${pad(d.getDate())}${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

// ── Command: verify ───────────────────────────────────────

function extractBugBlocks(reportText) {
  const lines = reportText.split('\n');
  const blocks = [];
  let buf = [];
  const flush = () => { if (buf.length) blocks.push(buf.join('\n')); buf = []; };
  for (const line of lines) {
    const isHeading = /^[#*]/.test(line);
    if (/🔴/.test(line) && isHeading) {
      flush();
      buf = [line];
      continue;
    }
    if (((/🟡/.test(line) || /🟢/.test(line)) && isHeading) ||
        /^#+\s*彙整表/.test(line) || /^#+\s*判定結果/.test(line)) {
      flush();
      continue;
    }
    if (buf.length) buf.push(line);
  }
  flush();
  return blocks;
}

function classifyVerdict(resultText) {
  const verdictLine = resultText.split('\n').find(l => /結論/.test(l));
  if (!verdictLine) return null;
  if (/FALSE\s+POSITIVE/.test(verdictLine)) return 'FALSE_POSITIVE';
  if (/CONFIRMED/.test(verdictLine)) return 'CONFIRMED';
  if (/POTENTIAL/.test(verdictLine)) return 'POTENTIAL';
  return null;
}

async function cmdVerify(reportFileArg, projectDirArg) {
  const totalStart = Date.now();
  let reportFile = reportFileArg || process.argv[3];
  if (!reportFile) reportFile = await ask('📋 請輸入 review 報告檔案路徑：');
  if (!reportFile || !existsSync(reportFile)) {
    console.log(`❌ 找不到檔案: ${reportFile}`);
    return;
  }
  const reportText = readFileSync(reportFile, 'utf8');

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

  // Engine: inherit from review if available
  let engine = inheritEngine();
  if (engine) {
    console.log('');
    console.log(`🤖 沿用 review 引擎: ${engineLabel(engine)}`);
  } else {
    engine = await pickEngine(['claude-opus', 'opencode', 'api'], 1, '選擇驗證引擎');
  }
  console.log(`   → 使用: ${engineLabel(engine)}`);
  console.log('');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('');

  const stepStart = Date.now();
  console.log('🔧 [1/2] 提取 🔴 BUG 級問題...');
  const blocks = extractBugBlocks(reportText);
  if (!blocks.length) {
    console.log('   ✅ 沒有找到 🔴 BUG 級問題');
    if (cloneCleanup) rmSync(projectDir, { recursive: true, force: true });
    return;
  }
  console.log(`   ✓ 找到 ${blocks.length} 個問題 (${Math.floor((Date.now() - stepStart) / 1000)}s)`);
  console.log('');
  blocks.forEach((b, i) => {
    const title = b.split('\n')[0].replace(/^#+\s*/, '').replace(/🔴\s*/, '').replace(/\*/g, '');
    console.log(`  [${i + 1}] ${title}`);
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
  let out = `## 🔍 BUG 驗證報告\n\n來源報告: \`${basename(reportFile)}\`\n\n`;

  const promptTemplate = readFileSync(join(PROMPTS_DIR, 'verify-bug.md'), 'utf8');
  let confirmed = 0, falsePositive = 0, potential = 0, verified = 0;
  const totalUsage = { input_tokens: 0, output_tokens: 0, cost_usd: 0 };

  for (let i = 0; i < blocks.length; i++) {
    if (selection !== 'a' && selection !== String(i + 1)) continue;
    const block = blocks[i];
    const title = block.split('\n')[0].replace(/^#+\s*/, '').replace(/🔴\s*/, '').replace(/\*/g, '');
    console.log(`   [${i + 1}/${blocks.length}] ${title}`);
    const prompt = `${promptTemplate}\n\n## The issue to verify\n\n${block}\n`;
    const { text, usage } = await withSpinner(`驗證問題 ${i + 1}`, runEngine(engine, prompt, projectDir));
    verified++;
    const verdict = classifyVerdict(text);
    if (verdict === 'CONFIRMED') confirmed++;
    else if (verdict === 'FALSE_POSITIVE') falsePositive++;
    else if (verdict === 'POTENTIAL') potential++;
    totalUsage.input_tokens += usage.input_tokens;
    totalUsage.output_tokens += usage.output_tokens;
    totalUsage.cost_usd += usage.cost_usd;
    out += `${text}\n\n---\n\n`;
    console.log('');
  }

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
