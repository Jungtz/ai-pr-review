### 🔴 BUG-level patterns

- **Off-by-one / boundary error**: 迴圈或 slice 的邊界條件錯誤，導致多取或少取一筆資料

  <example>
  ❌ 有問題：
  ```
  for (i = 0; i <= len; i++)   // 應為 < len，多迭代一次
  items[1:]                     // 跳過第一筆，是否為預期行為？
  ```
  ✅ 正確：
  ```
  for (i = 0; i < len; i++)
  ```
  </example>

- **Condition logic error**: 條件判斷反轉（`&&` vs `||`）、缺少 else/default branch、或否定條件寫反

  <example>
  ❌ 有問題：
  ```
  if (a && b) { ... }   // 應為 a || b，導致條件過嚴永遠不進入
  ```
  </example>

- **Race condition**: 多個非同步操作之間存在隱含的順序依賴，但沒有明確等待或同步機制

- **Error swallowed silently**: catch/except/recover 區塊為空或只有 log，沒有重新拋出或回傳錯誤狀態，導致上層無法得知失敗

  <example>
  ❌ 有問題：
  ```
  try { ... } catch (e) { console.log(e) }    // 呼叫端以為成功
  except Exception: pass                        // Python 靜默吞掉錯誤
  ```
  </example>

- **Resource leak**: 開啟的檔案、連線、subscription 沒有在所有路徑（包括 error path）中正確關閉或清理

- **Hardcoded secret / credential**: 程式碼中直接寫入 API key、密碼、token 等敏感資訊

### 🟡 WARN-level patterns

- **Duplicated logic**: 相同的邏輯出現在多處，應抽成共用函式

- **Inconsistent error handling**: 同一類操作在某些地方有錯誤處理，但在其他地方沒有

- **Magic number / string**: 程式碼中直接使用未命名的常數值，語意不明

- **Naming inconsistency**: 同一概念在不同檔案使用不同名稱

### 🟢 NIT-level patterns

- Deprecated 程式碼用註解包起來而非刪除（git history 可還原）
- 殘留的 debug 語句（console.log、print、fmt.Println 等）
- 未使用的變數或 import
