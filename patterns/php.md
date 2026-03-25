### 🔴 BUG-level patterns (PHP)

- **SQL injection**: 字串拼接建構 SQL 語句，未使用 prepared statement 或 parameter binding

  <example>
  ❌ 有問題：
  ```php
  $query = "SELECT * FROM users WHERE id = " . $_GET['id'];
  $db->query($query);
  ```
  ✅ 正確：
  ```php
  $stmt = $db->prepare("SELECT * FROM users WHERE id = ?");
  $stmt->execute([$_GET['id']]);
  ```
  </example>

- **XSS via unescaped output**: 使用者輸入直接 echo 到 HTML 中，未經 `htmlspecialchars()` 或其他 sanitize 處理

  <example>
  ❌ 有問題：
  ```php
  echo "<p>Hello, " . $_GET['name'] . "</p>";
  ```
  ✅ 正確：
  ```php
  echo "<p>Hello, " . htmlspecialchars($_GET['name'], ENT_QUOTES, 'UTF-8') . "</p>";
  ```
  </example>

- **Type juggling / loose comparison**: 使用 `==` 比較導致意外的型別轉換，特別是在驗證密碼、token、權限判斷等安全相關的場景

  <example>
  ❌ 有問題：
  ```php
  if ($token == "0") { ... }     // "0e12345" == "0" 為 true（科學記號）
  if ($password == $hash) { ... } // 兩個 "0e..." 字串會被當數字比較
  ```
  ✅ 正確：
  ```php
  if ($token === "0") { ... }
  if (hash_equals($hash, $computed)) { ... }
  ```
  </example>

- **Null reference on method chain**: 對可能回傳 `null` 的方法繼續鏈式呼叫，導致 "Call to a member function on null"

  <example>
  ❌ 有問題：
  ```php
  $user = User::find($id);
  $name = $user->profile->name;  // $user 可能為 null
  ```
  ✅ 正確：
  ```php
  $user = User::find($id);
  $name = $user?->profile?->name ?? 'Unknown';
  ```
  </example>

- **Unserialize on untrusted data**: 對使用者可控的資料使用 `unserialize()`，可能導致 object injection 攻擊

  <example>
  ❌ 有問題：
  ```php
  $data = unserialize($_COOKIE['prefs']);
  ```
  ✅ 正確：
  ```php
  $data = json_decode($_COOKIE['prefs'], true);
  // 或限制允許的 class
  $data = unserialize($input, ['allowed_classes' => false]);
  ```
  </example>

- **Array key overwrite in merge**: `array_merge()` 時 string key 重複，後者覆蓋前者，可能造成靜默資料遺失

  <example>
  ❌ 有問題：
  ```php
  $defaults = ['role' => 'admin'];
  $input = ['role' => 'user'];
  $config = array_merge($defaults, $input);  // role 被使用者覆蓋為 user（或反過來被覆蓋為 admin）
  ```
  </example>

### 🟡 WARN-level patterns (PHP)

- **Silenced error with `@`**: 使用 `@` 運算子抑制錯誤，隱藏了潛在問題

  <example>
  ❌ 有問題：
  ```php
  $value = @$array['key'];  // 隱藏了 undefined index 警告
  $conn = @mysqli_connect(...);  // 連線失敗也不會報錯
  ```
  </example>

- **Mixed return types**: 同一函式在不同路徑回傳不同型別（如有時回傳 array、有時回傳 `false`），呼叫端未處理所有可能

- **Missing CSRF protection**: 表單處理或狀態變更的 endpoint 沒有驗證 CSRF token

- **Inconsistent `empty()` / `isset()` usage**: 同一份資料在某些地方用 `isset()` 檢查、其他地方用 `empty()`，行為不同（`empty("0")` 為 `true`）
