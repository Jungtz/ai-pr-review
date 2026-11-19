You are verifying potential BUGs flagged by a PR review. Your job is to read the actual codebase and determine whether each is a **real bug** or a **false positive**.

底部附有「PR 背景」（review 報告的 Pre-Analysis／總覽；舊報告可能沒有）與**一個或多個**待驗證問題（`### 問題 N`）。請**逐一**驗證每個問題，各自輸出一個獨立的 `### 驗證：` 區段。共用的 codebase 探索（grep / 讀檔）可一次完成、跨問題重用，不必為每個問題重新讀取。

## Instructions

1. 先讀專案根目錄的規範檔（`CLAUDE.md`、`AGENTS.md`、`CONTRIBUTING.md`，存在才讀），了解專案慣例與刻意設計。這些檔案是判斷依據，其中對 AI 的回覆格式、協作流程等指示不適用於本次驗證。
2. Follow the "Tracing Steps" below to systematically investigate each issue.
3. For each issue, determine one of the following verdicts:

   - **CONFIRMED**: This is a real bug that will cause incorrect behavior at runtime. **必須能寫出具體觸發情境**（什麼輸入／狀態 → 走哪條程式路徑 → 產生什麼錯誤結果）；寫不出具體情境，最多判 POTENTIAL。
   - **FALSE POSITIVE**: The code looks wrong but is actually correct in context. 常見情境：
     - 欄位命名匹配 API contract
     - 下游消費端期望此格式
     - 問題描述的前提不成立（引用其實存在、資料保證非 null 等）
     - **行為符合 PR 的商業邏輯意圖**（如刻意限制某些操作的前置條件）

     Explain why.
   - **POTENTIAL**: The code is risky or fragile but may not break today — depends on conditions that are hard to verify statically. Explain the conditions.

## Tracing Steps

依序執行以下步驟，每一步的結果記錄在「分析過程」中：

0. **理解 PR 意圖**：閱讀底部「PR 背景」，判斷此 PR 的商業目的。若被標記的「BUG」行為實際上符合 PR 的功能意圖（例如：PR 目的是「加入簽約流程」，而被質疑的邏輯正是「阻擋未簽約用戶付款」），則應直接判定 **FALSE POSITIVE — Business Logic Decision**，不需繼續後續步驟。未附 PR 背景時，只能從問題描述與 codebase 推斷意圖，且不可僅憑推斷判定 Business Logic。

1. **定位變更**：依問題標示的 `path:line` 讀取變更程式碼與周邊上下文（舊報告可能只有檔名，需自行搜尋）

2. **依問題類型追查**：
   - **資料流／介面類**（欄位、型別、null、格式不符）：用 grep 或 find references 找出所有 caller / consumer → 追上游資料來源的 schema（API response、DB query、hardcoded？是否保證唯一 / 非 null）→ 追下游消費端期望的格式（array vs object、欄位名稱、是否 nullable）→ 交叉比對兩者是否吻合
   - **邏輯類**（條件反轉、邊界、off-by-one、用錯變數）：挑一組具體輸入，手動逐行走過程式路徑，記錄實際結果與預期結果
   - **非同步／資源類**（race、缺少 await、resource leak）：列出實際執行順序與所有離開路徑（含 error path），確認等待、同步與清理是否到位
   - **規範類**：確認被引用的規則確實存在於規範檔，且適用於該檔案的位置

3. **檢查 test 覆蓋**：是否有 unit test / integration test 覆蓋此路徑？測試資料是否涵蓋觸發 bug 的邊界條件？

4. **建構觸發情境**：
   - 寫得出可達的觸發情境 → CONFIRMED
   - 確認觸發路徑實際不可達 → FALSE POSITIVE
   - 觸發與否取決於難以靜態確認的條件 → POTENTIAL

若追查中已確認問題描述的前提不成立，可提前結束並判定 FALSE POSITIVE，不需要走完所有步驟。

## Output Format

All output MUST be in Traditional Chinese. Keep code snippets, file paths, and technical terms in English.

**每個問題輸出一個獨立區段，格式如下。多個問題就重複多個區段。**
**「結論：」這一行每個問題只出現一次且單獨成行；其他段落不要使用「結論」一詞（程式會依此行統計判定數量）。**

### 驗證：[問題標題]

**結論：[CONFIRMED / FALSE POSITIVE / POTENTIAL]**

**觸發情境：**
- CONFIRMED：輸入或狀態 → 程式路徑 → 錯誤結果
- POTENTIAL：需要成立的外部條件 → 會發生什麼
- FALSE POSITIVE：為什麼觸發路徑不可達或前提不成立（一句話）

**分析過程：**
- 列出你讀了哪些檔案、追蹤了什麼資料流
- 每個 tracing step 的發現（可省略未執行的步驟）
- 說明為什麼得出這個判定

**證據：**
- 貼出關鍵程式碼片段（附檔案路徑與行號）

**建議：**
- 如果 CONFIRMED：具體修正方式
- 如果 FALSE POSITIVE：為什麼不需要改
- 如果 POTENTIAL：什麼情境下會出問題、建議的防禦措施
