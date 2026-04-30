# ai-pr-review

AI-powered GitHub PR review tool — 自動取得 PR diff，透過 AI 分析潛在問題，並可對 BUG 級問題進行深度驗證。

## 需求

| 工具 | 用途 | 安裝 |
|------|------|------|
| [gh](https://cli.github.com) | 取得 PR 資訊與 diff | `brew install gh` / `winget install GitHub.cli` |
| [jq](https://jqlang.github.io/jq) | 解析 JSON | `brew install jq` / `winget install jqlang.jq` |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | AI 引擎（預設） | `npm install -g @anthropic-ai/claude-code` |
| [opencode](https://opencode.ai) | AI 引擎（選用） | `npm install -g opencode-ai` |
| OpenAI 相容 API | AI 引擎（Ollama / OpenRouter / 其他） | 提供 API Base URL、API Key、Model 名稱 |

使用前請先登入 GitHub CLI：

```bash
gh auth login
```

## 檔案結構

```
ai-pr-review/
├── review-pr.command    # macOS 主程式（雙擊啟動，wrapper）
├── review-pr.bat        # Windows 主程式（雙擊啟動，wrapper）
├── verify-bug.command   # macOS BUG 驗證（wrapper）
├── verify-bug.bat       # Windows BUG 驗證（wrapper）
├── bin/
│   └── cli.mjs          # 實際邏輯（Node 18+，零依賴）
├── prompts/
│   ├── review-pr.md     # Review prompt 模板（含 {{PATTERNS}} 佔位符）
│   ├── verify-bug.md    # BUG 驗證 prompt 模板
│   └── patterns.md      # 通用 detection patterns（跨語言）
└── results/             # 輸出報告（.gitignore）
    ├── PR_*_.md         # Review 報告
    └── PR_*_verify.md   # 驗證報告
```

> 前置依賴：`node` (>= 18)、`gh` CLI；視所選引擎還需 `claude` 或 `opencode` 或 `curl`。

## 使用方式

### macOS

雙擊 `review-pr.command`，或在終端執行：

```bash
./review-pr.command
```

### Windows

雙擊 `review-pr.bat`，或在命令提示字元執行：

```cmd
review-pr.bat
```

## 流程

### Step 1：PR Review

```
📋 貼上 PR 連結
        ↓
🤖 選擇 AI 引擎
   [1] Claude Sonnet（預設）
   [2] Claude Opus（深度分析）
   [3] opencode
   [4] OpenAI 相容 API（Ollama / OpenRouter / 其他）
   [5] 自訂指令
        ↓
📄 選擇輸出方式
   [1] 儲存為檔案
   [2] 預覽（less / more）
        ↓
📡 自動取得 PR 資訊 + diff（via gh CLI）
        ↓
🔧 載入通用 detection patterns
        ↓
🤖 AI 分析（區分商業邏輯意圖，優化 BUG 判定） → 產出 review 報告
        ↓
📊 顯示彙整表 + 儲存報告
        ↓
🔍 若有 🔴 BUG 級問題 → 詢問是否進入深度驗證（預設為 Y）
```

### Step 2：BUG 驗證（verify-bug）

當 review 報告包含 🔴 BUG 級問題時，可進行深度驗證：

```
📋 輸入 review 報告路徑（或由 Step 1 自動帶入）
        ↓
📂 取得專案原始碼
   - 自動從報告 metadata 取得 repo/branch 並 clone
   - 或手動輸入本地專案路徑
        ↓
🤖 選擇驗證引擎
   [1] Claude Opus（預設）
   [2] opencode
   [3] OpenAI 相容 API（Ollama / OpenRouter / 其他）
        ↓
🔧 提取報告中所有 🔴 問題
        ↓
   選擇要驗證的問題（單一 / 全部）
        ↓
🤖 AI 逐一讀取原始碼進行驗證
   - CONFIRMED：確認是 BUG
   - FALSE POSITIVE：誤報
   - POTENTIAL：潛在風險
        ↓
📊 輸出驗證摘要 + 儲存報告
```

## 輸出範例

Review 報告儲存為 `PR_{number}_{timestamp}.md`，包含：

- PR 總覽（標題、作者、分支、變更統計）
- 問題清單（🔴 BUG / 🟡 WARN / 🟢 NIT）
- 彙整表
- 判定結果（APPROVE / REQUEST CHANGES / COMMENT）

驗證報告儲存為 `PR_{number}_{timestamp}_verify.md`，包含：

- 每個 🔴 問題的驗證結論與分析過程
- 驗證摘要統計

## Detection Patterns

`prompts/patterns.md` 定義了通用的 detection checklist（邊界條件、邏輯錯誤、race condition、資源洩漏、安全問題等）。

語言特定的 pattern 不需要額外維護 — AI 本身已具備各語言的深度知識，通用 checklist 足以引導分析方向。

## 自訂 Prompt

- `prompts/review-pr.md` — Review 主模板，`{{PATTERNS}}` 佔位符會被替換為 `prompts/patterns.md` 的內容
- `prompts/verify-bug.md` — BUG 驗證 prompt 模板
- `prompts/patterns.md` — 通用 detection checklist，可自由修改
- `bin/cli.mjs` — 實際的 Node 邏輯（review / verify 兩個 sub-command）

## License

本專案採用 [MIT License](LICENSE) 開源授權。
