Review the GitHub PR based on the data provided below.

## Instructions

- The PR metadata (JSON) and diff are already attached at the bottom of this prompt. Do NOT run any commands to fetch them — use the provided data directly.
- Read the entire diff carefully. Only analyze the changed lines and their immediate context — do NOT review unchanged code or raise issues unrelated to the diff.
- Review each changed line against the "Detection Checklist" below. Only report issues that actually appear in the diff.
- All output MUST be in Traditional Chinese (繁體中文). Keep code snippets, file paths, and technical terms in English.

## Detection Checklist

{{PATTERNS}}

## Do NOT Report

以下項目不屬於本 review 範圍，請勿報告：

- **純風格 / 格式問題**：縮排、空格、分號、換行等 — 這些由 linter / formatter 處理
- **型別標註缺失**：由 TypeScript 編譯器或 type checker 負責
- **缺少 JSDoc / 註解**：除非邏輯極度不直觀，否則不報告
- **對未變更程式碼的建議**：只 review diff 中的變更，不要對既有程式碼提意見
- **已有 test 覆蓋的邊界情境**：如果 diff 中可見對應 test，不需重複提醒
- **主觀偏好**：命名風格、程式碼組織方式等無明確對錯之分的選擇

## Output Format

### 總覽
- PR 標題、作者、分支、狀態
- 用 2-3 句話總結這個 PR 做了什麼
- 變更檔案數、新增/刪除行數

### 問題清單

只針對 diff 中實際變更的程式碼，列出發現的問題。每個問題用以下格式詳細說明：

**[燈號] 問題標題** `[信心度]`
- 檔案：`path/to/file` 相關程式碼片段
- 說明：問題是什麼、為什麼有風險
- 建議：如何修正

信心度標準：
- **HIGH**：從 diff 中可直接確認的問題，不需額外上下文
- **MEDIUM**：需要看更多 codebase 上下文才能確認（建議用 verify-bug 驗證）
- **LOW**：可能是問題，取決於執行環境或外部條件

如果沒有發現問題，直接寫「沒有發現問題」。不要為了湊數而硬找問題。

### 彙整表

在報告最末端輸出一個總結表格，讓人只看這張表就能掌握全貌：

| # | 燈號 | 信心度 | 檔案 | 問題摘要 |
|---|------|--------|------|----------|
| 1 | 🔴 | HIGH | `path/to/file` | 一句話描述 |
| 2 | 🟡 | MEDIUM | `path/to/file` | 一句話描述 |
| ... | | | | |

**判定結果：**
- 🟢 **APPROVE（通過）**：沒有 🔴 BUG 級問題
- 🔴 **REQUEST CHANGES（要求修改）**：有 🔴 BUG 級 HIGH/MEDIUM 信心度問題，列出必須修正的項目
- 🟡 **COMMENT（建議）**：只有 🟡 WARN / 🟢 NIT 級問題，或只有 LOW 信心度的 🔴 問題

統計：🔴 x 個 / 🟡 x 個 / 🟢 x 個
