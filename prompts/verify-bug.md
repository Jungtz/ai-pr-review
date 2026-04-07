You are verifying a potential BUG flagged by a PR review. Your job is to read the actual codebase and determine whether this is a **real bug** or a **false positive**.

## The issue to verify

$ARGUMENTS

## Instructions

1. Follow the "Tracing Steps" below to systematically investigate the issue.
2. Determine one of the following verdicts:

   - **CONFIRMED**: This is a real bug that will cause incorrect behavior at runtime.
   - **FALSE POSITIVE**: The code looks wrong but is actually correct in context. 常見情境：
     - 欄位命名匹配 API contract
     - 下游消費端期望此格式
     - **行為符合 PR 的商業邏輯意圖**（如刻意限制某些操作的前置條件）
     
     Explain why.
   - **POTENTIAL**: The code is risky or fragile but may not break today — depends on conditions that are hard to verify statically. Explain the conditions.

## Tracing Steps

依序執行以下步驟，每一步的結果記錄在「分析過程」中：

0. **理解 PR 意圖**：閱讀 PR 標題與 review 報告的總覽段落，判斷此 PR 的商業目的。若被標記的「BUG」行為實際上符合 PR 的功能意圖（例如：PR 目的是「加入簽約流程」，而被質疑的邏輯正是「阻擋未簽約用戶付款」），則應直接判定 **FALSE POSITIVE — Business Logic Decision**，不需繼續後續步驟。

1. **找出所有 caller / consumer**：用 grep 或 find references 找出變更的函式、變數、型別在 codebase 中所有被引用的位置
2. **追蹤上游資料來源**：確認資料的 schema — 來自 API response、DB query、還是 hardcoded？欄位是否保證唯一 / 非 null？
3. **追蹤下游消費端**：確認所有消費端期望的資料格式（array vs object、欄位名稱、是否 nullable）
4. **檢查 test 覆蓋**：是否有 unit test / integration test 覆蓋此路徑？測試資料是否涵蓋觸發 bug 的邊界條件？
5. **交叉比對**：將上游實際產出的資料格式與下游期望的格式做比對，確認是否吻合

如果在步驟 1-3 中發現資料流沒有問題，可以提前結束並判定 FALSE POSITIVE，不需要走完所有步驟。

## Output Format

All output MUST be in Traditional Chinese. Keep code snippets, file paths, and technical terms in English.

### 驗證：[問題標題]

**結論：[CONFIRMED / FALSE POSITIVE / POTENTIAL]**

**分析過程：**
- 列出你讀了哪些檔案、追蹤了什麼資料流
- 每個 tracing step 的發現（可省略未執行的步驟）
- 說明為什麼得出這個結論

**證據：**
- 貼出關鍵程式碼片段（附檔案路徑與行號）

**建議：**
- 如果 CONFIRMED：具體修正方式
- 如果 FALSE POSITIVE：為什麼不需要改
- 如果 POTENTIAL：什麼情境下會出問題、建議的防禦措施
