#!/bin/bash

# Bug Verification Script
# Usage:
#   ./verify-bug.command <review-report.md> [project-path]
#   Called automatically from review-pr.command when user opts in

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/lib/api-helper.sh"

PROMPT_FILE="$SCRIPT_DIR/prompts/verify-bug.md"
API_CONFIG="$SCRIPT_DIR/.api-config"
TOTAL_START=$SECONDS

# Strip ANSI escape codes
strip_ansi() {
  sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | sed $'s/\x1b\[[0-9;]*m//g' | sed $'s/\r//g; s/\x04//g; s/\x08//g'
}

# Run AI verification in project directory
run_verify() {
  local engine=$1
  local prompt_file=$2
  local output_file=$3
  local project_dir=$4
  local raw_file="${output_file}.raw"

  case "$engine" in
    1)
      (cd "$project_dir" && claude -p --model opus --output-format json < "$prompt_file" > "$raw_file")
      jq -r '.result // empty' "$raw_file" > "$output_file"
      jq '{input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens, cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, cost_usd: .total_cost_usd}' "$raw_file" > "${output_file}.usage" 2>/dev/null
      rm -f "$raw_file"
      ;;
    2)
      local prompt_content
      prompt_content=$(cat "$prompt_file")
      (cd "$project_dir" && opencode run --format json "$prompt_content" > "$raw_file" 2>/dev/null)
      jq -r 'select(.type=="text") | .part.text // empty' "$raw_file" > "$output_file"
      jq -r 'select(.type=="step_finish") | .part' "$raw_file" | jq -s 'last | {input_tokens: .tokens.input, output_tokens: .tokens.output, cache_creation: .tokens.cache.write, cache_read: .tokens.cache.read, cost_usd: .cost}' > "${output_file}.usage" 2>/dev/null
      rm -f "$raw_file"
      ;;
    3)
      (cd "$project_dir" && run_api "$API_BASE" "$API_KEY" "$API_MODEL" "$prompt_file" "$output_file")
      ;;
  esac
}

ENGINE_LABELS=("" "Claude Opus" "opencode" "")

# Timer helper
step_time() {
  local start=$1
  local elapsed=$(( SECONDS - start ))
  echo "(${elapsed}s)"
}

# Spinner function
spin() {
  local pid=$1
  local label=${2:-"驗證中"}
  local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  local i=0
  local start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    local elapsed=$(( SECONDS - start ))
    local min=$(( elapsed / 60 ))
    local sec=$(( elapsed % 60 ))
    printf "\r   ⏳ ${label} ${chars:i++%${#chars}:1} %02d:%02d " "$min" "$sec"
    sleep 0.1
  done
  local elapsed=$(( SECONDS - start ))
  printf "\r   ✓ 完成 (${elapsed}s)              \n"
}

# Step 1: 取得報告檔案
REPORT_FILE="$1"

if [ -z "$REPORT_FILE" ]; then
  echo "📋 請輸入 review 報告檔案路徑："
  read -r REPORT_FILE
fi

if [ -z "$REPORT_FILE" ] || [ ! -f "$REPORT_FILE" ]; then
  echo "❌ 找不到檔案: ${REPORT_FILE}"
  echo ""
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi

# 取得專案路徑：參數 > 報告 metadata auto-clone > 手動輸入
PROJECT_DIR="$2"

if [ -z "$PROJECT_DIR" ]; then
  # 嘗試從報告的 metadata 取得 repo 和 branch，自動 clone
  META_LINE=$(grep '<!-- verify-meta:' "$REPORT_FILE" 2>/dev/null)
  if [ -n "$META_LINE" ]; then
    META_REPO=$(echo "$META_LINE" | grep -oE 'repo=[^ ]+' | sed 's/repo=//')
    META_BRANCH=$(echo "$META_LINE" | grep -oE 'branch=[^ ]+' | sed 's/branch=//' | sed 's/ *-->.*//')
    if [ -n "$META_REPO" ] && [ -n "$META_BRANCH" ]; then
      echo "📂 從報告取得 repo: ${META_REPO} (${META_BRANCH})"
      echo "   正在 clone..."
      PROJECT_DIR=$(mktemp -d)
      CLONE_CLEANUP=true
      gh repo clone "$META_REPO" "$PROJECT_DIR" -- --depth 1 --branch "$META_BRANCH" --single-branch 2>/dev/null
      if [ $? -ne 0 ]; then
        echo "❌ Clone 失敗"
        rm -rf "$PROJECT_DIR"
        echo ""
        echo "按任意鍵關閉..."
        read -n 1
        exit 1
      fi
      echo "   ✓ Clone 完成"
    fi
  fi
fi

if [ -z "$PROJECT_DIR" ]; then
  echo ""
  echo "📂 請輸入專案路徑（驗證需要讀取原始碼）："
  read -r PROJECT_DIR
fi

if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
  echo "❌ 無效的專案路徑: ${PROJECT_DIR}"
  echo ""
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi

# 轉為絕對路徑
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
echo "   → 專案: ${PROJECT_DIR}"

# 選擇 AI 引擎（若從 review-pr 傳入 API 設定則自動沿用）
if [ "$PR_REVIEW_ENGINE" = "api" ] && [ -n "$API_BASE" ] && [ -n "$API_MODEL" ]; then
  ENGINE_CHOICE=3
  echo ""
  echo "🤖 沿用 review 引擎: API (${API_MODEL} @ ${API_BASE})"
else
  echo ""
  echo "🤖 選擇驗證引擎："
  echo "  [1] Claude Opus（預設）"
  echo "  [2] opencode"
  echo "  [3] OpenAI 相容 API（Ollama / OpenRouter / 其他）"
  echo ""
  read -r -p "選擇 [1/2/3]（直接 Enter 為 1）: " ENGINE_CHOICE
  ENGINE_CHOICE=${ENGINE_CHOICE:-1}

  if [ "$ENGINE_CHOICE" = "3" ]; then
    echo ""
    prompt_api_settings "$API_CONFIG"
  fi
fi

case "$ENGINE_CHOICE" in
  3) echo "   → 使用: API (${API_MODEL} @ ${API_BASE})" ;;
  *) echo "   → 使用: ${ENGINE_LABELS[$ENGINE_CHOICE]:-$ENGINE_CHOICE}" ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 2: 提取 🔴 問題區塊
STEP_START=$SECONDS
echo "🔧 [1/2] 提取 🔴 BUG 級問題..."

TMPDIR=$(mktemp -d)
awk -v dir="$TMPDIR" '
  function flush() {
    if (buf != "") {
      count++
      fname = dir "/bug_" count ".txt"
      print buf > fname
      close(fname)
    }
  }
  /🔴/ && /^[#*]/ {
    flush()
    buf = $0
    next
  }
  /🟡/ && /^[#*]/ || /🟢/ && /^[#*]/ || /^##* *彙整表/ || /^##* *判定結果/ {
    flush()
    buf = ""
    next
  }
  buf != "" { buf = buf "\n" $0 }
  END { flush() }
' "$REPORT_FILE"

BUG_FILES=$(ls "$TMPDIR"/bug_*.txt 2>/dev/null | sort -V)
if [ -z "$BUG_FILES" ]; then
  echo "   ✅ 沒有找到 🔴 BUG 級問題"
  rm -rf "$TMPDIR"
  echo ""
  echo "按任意鍵關閉..."
  read -n 1
  exit 0
fi

BUG_COUNT=$(echo "$BUG_FILES" | wc -l | tr -d ' ')
echo "   ✓ 找到 ${BUG_COUNT} 個問題 $(step_time $STEP_START)"
echo ""

# 列出所有問題
ISSUE_NUM=0
for BUG_FILE in $BUG_FILES; do
  ISSUE_NUM=$((ISSUE_NUM + 1))
  TITLE=$(head -1 "$BUG_FILE" | sed 's/^#* *//' | sed 's/🔴 *//' | sed 's/\*//g')
  echo "  [${ISSUE_NUM}] ${TITLE}"
done
echo ""
echo "  [a] 全部驗證"
echo ""
read -r -p "選擇要驗證的問題（數字/a，直接 Enter 為全部）: " SELECTION
SELECTION=${SELECTION:-a}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 3: 逐一驗證
echo "🤖 [2/2] AI 深度驗證..."
echo ""

VERIFY_FILENAME="${REPORT_FILE%.md}_verify.md"
{
  echo "## 🔍 BUG 驗證報告"
  echo ""
  echo "來源報告: \`$(basename "$REPORT_FILE")\`"
  echo ""
} > "$VERIFY_FILENAME"

PROMPT_TEMPLATE=$(cat "$PROMPT_FILE")
VERIFIED=0
CONFIRMED=0
FALSE_POSITIVE=0
POTENTIAL=0
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0
TOTAL_COST_USD=0

ISSUE_NUM=0
for BUG_FILE in $BUG_FILES; do
  ISSUE_NUM=$((ISSUE_NUM + 1))

  # 如果不是全部，檢查是否為選中的問題
  if [ "$SELECTION" != "a" ] && [ "$SELECTION" != "$ISSUE_NUM" ]; then
    continue
  fi

  ISSUE_CONTENT=$(cat "$BUG_FILE")
  TITLE=$(head -1 "$BUG_FILE" | sed 's/^#* *//' | sed 's/🔴 *//' | sed 's/\*//g')
  echo "   [${ISSUE_NUM}/${BUG_COUNT}] ${TITLE}"

  # 組合 prompt
  PROMPT_TMPFILE=$(mktemp)
  cat > "$PROMPT_TMPFILE" <<EOF
${PROMPT_TEMPLATE}

## The issue to verify

${ISSUE_CONTENT}
EOF

  TMPFILE=$(mktemp)
  run_verify "$ENGINE_CHOICE" "$PROMPT_TMPFILE" "$TMPFILE" "$PROJECT_DIR" &
  spin $! "驗證問題 ${ISSUE_NUM}"
  rm -f "$PROMPT_TMPFILE"

  RESULT=$(cat "$TMPFILE")

  # 統計結果
  VERIFIED=$((VERIFIED + 1))
  if echo "$RESULT" | grep -q "CONFIRMED"; then
    CONFIRMED=$((CONFIRMED + 1))
  elif echo "$RESULT" | grep -q "FALSE POSITIVE"; then
    FALSE_POSITIVE=$((FALSE_POSITIVE + 1))
  elif echo "$RESULT" | grep -q "POTENTIAL"; then
    POTENTIAL=$((POTENTIAL + 1))
  fi

  # 累計 token 用量
  if [ -f "${TMPFILE}.usage" ]; then
    ISSUE_INPUT=$(jq -r '.input_tokens // 0' "${TMPFILE}.usage" 2>/dev/null)
    ISSUE_OUTPUT=$(jq -r '.output_tokens // 0' "${TMPFILE}.usage" 2>/dev/null)
    ISSUE_COST=$(jq -r '.cost_usd // 0' "${TMPFILE}.usage" 2>/dev/null)
    TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + ISSUE_INPUT))
    TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + ISSUE_OUTPUT))
    TOTAL_COST_USD=$(echo "$TOTAL_COST_USD + $ISSUE_COST" | bc)
    rm -f "${TMPFILE}.usage"
  fi

  {
    cat "$TMPFILE"
    echo ""
    echo "---"
    echo ""
  } >> "$VERIFY_FILENAME"

  rm -f "$TMPFILE"
  echo ""
done

rm -rf "$TMPDIR"

# 清理暫存 clone
if [ "${CLONE_CLEANUP:-false}" = "true" ]; then
  rm -rf "$PROJECT_DIR"
fi

# 附加統計摘要
TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
TOTAL_MIN=$(( TOTAL_ELAPSED / 60 ))
TOTAL_SEC=$(( TOTAL_ELAPSED % 60 ))

{
  echo "## 📊 驗證摘要"
  echo ""
  echo "| 結論 | 數量 |"
  echo "|------|------|"
  echo "| 🔴 CONFIRMED（確認是 BUG） | ${CONFIRMED} |"
  echo "| ✅ FALSE POSITIVE（誤報） | ${FALSE_POSITIVE} |"
  echo "| ⚠️ POTENTIAL（潛在風險） | ${POTENTIAL} |"
  echo "| **合計驗證** | **${VERIFIED}** |"
  echo ""
  printf "⏱ 驗證耗時 %02d:%02d\n" "$TOTAL_MIN" "$TOTAL_SEC"
  echo ""
  echo "| 項目 | 數值 |"
  echo "|------|------|"
  printf "| Input tokens | %'d |\n" "$TOTAL_INPUT_TOKENS"
  printf "| Output tokens | %'d |\n" "$TOTAL_OUTPUT_TOKENS"
  printf "| 費用 | \$%.4f |\n" "$TOTAL_COST_USD"
  echo ""
  echo "---"
  case "$ENGINE_CHOICE" in
    3) ENGINE_NAME="API (${API_MODEL})" ;;
    *) ENGINE_NAME="${ENGINE_LABELS[$ENGINE_CHOICE]:-$ENGINE_CHOICE}" ;;
  esac
  printf "Model: %s | Total: %02d:%02d | Tokens: %d in / %d out | Cost: \$%.4f\n" "$ENGINE_NAME" "$TOTAL_MIN" "$TOTAL_SEC" "$TOTAL_INPUT_TOKENS" "$TOTAL_OUTPUT_TOKENS" "$TOTAL_COST_USD"
} >> "$VERIFY_FILENAME"

# 輸出摘要
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 驗證結果："
echo "   🔴 CONFIRMED: ${CONFIRMED}"
echo "   ✅ FALSE POSITIVE: ${FALSE_POSITIVE}"
echo "   ⚠️  POTENTIAL: ${POTENTIAL}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "✅ 驗證報告已儲存至 %s\n" "${VERIFY_FILENAME}"
printf "⏱  總耗時 %02d:%02d\n" "$TOTAL_MIN" "$TOTAL_SEC"
printf "📊 Tokens: %'d in / %'d out | 費用: \$%.4f\n" "$TOTAL_INPUT_TOKENS" "$TOTAL_OUTPUT_TOKENS" "$TOTAL_COST_USD"
echo ""
echo "按任意鍵關閉..."
read -n 1
