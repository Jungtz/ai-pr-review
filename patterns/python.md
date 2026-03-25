### 🔴 BUG-level patterns (Python)

- **Mutable default argument**: 函式參數使用 mutable 預設值（`list`, `dict`, `set`），多次呼叫會共享同一個物件

  <example>
  ❌ 有問題：
  ```python
  def add_item(item, items=[]):
      items.append(item)  # 所有呼叫共享同一個 list
      return items
  ```
  ✅ 正確：
  ```python
  def add_item(item, items=None):
      if items is None:
          items = []
      items.append(item)
      return items
  ```
  </example>

- **Late binding closure**: 迴圈中建立 lambda 或 closure，變數在執行時才綁定，導致所有 closure 都引用最後一次迭代的值

  <example>
  ❌ 有問題：
  ```python
  funcs = [lambda: i for i in range(5)]
  funcs[0]()  # 回傳 4，不是 0
  ```
  ✅ 正確：
  ```python
  funcs = [lambda i=i: i for i in range(5)]
  ```
  </example>

- **Bare except / broad exception**: `except Exception` 或 `except:` 捕捉過廣，可能吞掉 `KeyboardInterrupt`、`SystemExit` 等不該捕捉的例外

- **Iterator exhaustion**: 對 generator 或 iterator 進行多次迭代，第二次起取得空結果

  <example>
  ❌ 有問題：
  ```python
  rows = (transform(r) for r in data)
  total = sum(rows)
  avg = sum(rows) / len(data)  # rows 已耗盡，sum 為 0
  ```
  ✅ 正確：
  ```python
  rows = list(transform(r) for r in data)
  ```
  </example>

- **SQL injection**: 字串拼接建構 SQL 語句，未使用 parameterized query

  <example>
  ❌ 有問題：
  ```python
  cursor.execute(f"SELECT * FROM users WHERE id = {user_id}")
  ```
  ✅ 正確：
  ```python
  cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,))
  ```
  </example>

- **Incorrect `is` comparison**: 對非 singleton 值使用 `is` 而非 `==`，CPython 的 integer cache 可能讓小數值巧合通過但大數值失敗

  <example>
  ❌ 有問題：
  ```python
  if status_code is 200:  # 可能失敗
  ```
  ✅ 正確：
  ```python
  if status_code == 200:
  ```
  </example>

### 🟡 WARN-level patterns (Python)

- **Missing `async` / `await`**: 呼叫 async function 但忘記 `await`，得到 coroutine object 而非結果

- **Unguarded `__name__`**: 模組層級的副作用程式碼（如啟動 server）未包在 `if __name__ == '__main__':` 中，被 import 時會意外執行

- **Dict `.get()` vs `[]` inconsistency**: 同一份 dict 在某些地方用 `.get()` 有預設值，其他地方直接 `[]` 存取，行為不一致
