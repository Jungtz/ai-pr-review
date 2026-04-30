#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/api-helper.sh"

PROMPT_FILE="$SCRIPT_DIR/prompts/review-pr.md"
API_CONFIG="$SCRIPT_DIR/.api-config"
TOTAL_START=$SECONDS

run_ai() {
  local engine=$1
  local prompt_file=$2
  local output_file=$3
  local prompt_content
  prompt_content=$(cat "$prompt_file")
  local raw_file="${output_file}.raw"

  case "$engine" in
    1)
      echo "$prompt_content" | claude -p --model sonnet --output-format json > "$raw_file"
      jq -r '.result // empty' "$raw_file" > "$output_file"
      jq '{input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens, cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, cost_usd: .total_cost_usd}' "$raw_file" > "${output_file}.usage" 2>/dev/null
      rm -f "$raw_file"
      ;;
    2)
      echo "$prompt_content" | claude -p --model opus --output-format json > "$raw_file"
      jq -r '.result // empty' "$raw_file" > "$output_file"
      jq '{input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens, cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, cost_usd: .total_cost_usd}' "$raw_file" > "${output_file}.usage" 2>/dev/null
      rm -f "$raw_file"
      ;;
    3)
      opencode run --format json "$prompt_content" > "$raw_file" 2>/dev/null
      jq -r 'select(.type=="text") | .part.text // empty' "$raw_file" > "$output_file"
      jq -r 'select(.type=="step_finish") | .part' "$raw_file" | jq -s 'last | {input_tokens: .tokens.input, output_tokens: .tokens.output, cache_creation: .tokens.cache.write, cache_read: .tokens.cache.read, cost_usd: .cost}' > "${output_file}.usage" 2>/dev/null
      rm -f "$raw_file"
      ;;
    4)
      run_api "$API_BASE" "$API_KEY" "$API_MODEL" "$prompt_file" "$output_file"
      ;;
    *) eval "$engine" < "$prompt_file" > "$output_file"; echo '{}' > "${output_file}.usage" ;;
  esac
}

ENGINE_LABELS=("" "Claude Sonnet" "Claude Opus" "opencode" "" "自訂")

# Step 1: 輸入 PR 連結
echo "📋 請貼上 PR 連結："
read -r PR_URL

if [ -z "$PR_URL" ]; then
  echo "❌ 未輸入 PR 連結"
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi

# 解析 owner/repo 和 PR number
REPO=$(echo "$PR_URL" | grep -oE 'github\.com/[^/]+/[^/]+' | sed 's|github\.com/||')
PR_NUMBER=$(echo "$PR_URL" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+')

if [ -z "$PR_NUMBER" ] || [ -z "$REPO" ]; then
  echo "❌ 無法解析 PR 連結"
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi

# Step 2: 選擇 AI 引擎（讀取快取作為預設值）
CACHED_ENGINE=$(grep '^ENGINE=' "$API_CONFIG" 2>/dev/null | cut -d= -f2-)
CACHED_ENGINE=${CACHED_ENGINE:-1}

echo ""
echo "🤖 選擇 AI 引擎："
echo "  [1] Claude Sonnet（正式 review）"
echo "  [2] Claude Opus（深度分析）"
echo "  [3] opencode"
echo "  [4] OpenAI 相容 API（Ollama / OpenRouter / 其他）"
echo "  [5] 自訂指令"
echo ""
read -r -p "選擇 [1/2/3/4/5]（直接 Enter 為 ${CACHED_ENGINE}）: " ENGINE_CHOICE
ENGINE_CHOICE=${ENGINE_CHOICE:-$CACHED_ENGINE}

if [ "$ENGINE_CHOICE" = "4" ]; then
  echo ""
  prompt_api_settings "$API_CONFIG"
  ENGINE_LABELS[4]="API (${API_MODEL})"
fi

if [ "$ENGINE_CHOICE" = "5" ]; then
  echo ""
  echo "請輸入自訂指令（需支援 stdin 輸入，stdout 輸出）："
  echo "範例: claude -p --model haiku"
  read -r ENGINE_CHOICE
fi

# 快取引擎選擇
if grep -q '^ENGINE=' "$API_CONFIG" 2>/dev/null; then
  sed -i '' "s/^ENGINE=.*/ENGINE=$ENGINE_CHOICE/" "$API_CONFIG"
else
  echo "ENGINE=$ENGINE_CHOICE" >> "$API_CONFIG"
fi

case "$ENGINE_CHOICE" in
  4) echo "   → 使用: API (${API_MODEL} @ ${API_BASE})" ;;
  *) echo "   → 使用: ${ENGINE_LABELS[$ENGINE_CHOICE]:-$ENGINE_CHOICE}" ;;
esac

TIMESTAMP=$(date +%y%m%d%H%M%S)
FILENAME="results/PR_${PR_NUMBER}_${TIMESTAMP}.md"
mkdir -p "$SCRIPT_DIR/results"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 4+5: 並行取得 PR 資訊 + diff
STEP_START=$SECONDS
echo "📡 [1/3] 取得 PR 資訊 + diff..."

DIFF_TMPFILE=$(mktemp)
gh pr diff "$PR_NUMBER" --repo "$REPO" > "$DIFF_TMPFILE" 2>&1 &
DIFF_PID=$!

PR_META=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title,additions,deletions,changedFiles,state,author,baseRefName,headRefName 2>&1)
if [ $? -ne 0 ]; then
  echo "❌ 無法取得 PR 資訊: $PR_META"
  wait $DIFF_PID; rm -f "$DIFF_TMPFILE"
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi

PR_TITLE=$(echo "$PR_META" | jq -r '.title')
PR_FILES=$(echo "$PR_META" | jq -r '.changedFiles')
PR_ADD=$(echo "$PR_META" | jq -r '.additions')
PR_DEL=$(echo "$PR_META" | jq -r '.deletions')
PR_HEAD_BRANCH=$(echo "$PR_META" | jq -r '.headRefName')
echo "   ✓ ${PR_TITLE}"
echo "   ✓ ${PR_FILES} 個檔案 | +${PR_ADD} -${PR_DEL}"

wait $DIFF_PID
DIFF_EXIT=$?
PR_DIFF=$(cat "$DIFF_TMPFILE")
rm -f "$DIFF_TMPFILE"
if [ $DIFF_EXIT -ne 0 ]; then
  echo "❌ 無法取得 diff: $PR_DIFF"
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi
DIFF_LINES=$(echo "$PR_DIFF" | wc -l | tr -d ' ')
echo "   ✓ ${DIFF_LINES} 行 diff $(step_time $STEP_START)"
echo ""

# Step 6: 偵測語言並組合 prompt
STEP_START=$SECONDS
echo "🔧 [2/3] 準備分析資料..."

# 從 diff 檔案副檔名偵測語言
DETECTED_LANGS=""
if echo "$PR_DIFF" | grep -qE '^\+\+\+ b/.*\.(js|ts|tsx|jsx|mjs|cjs)$'; then
  DETECTED_LANGS="$DETECTED_LANGS javascript"
fi
if echo "$PR_DIFF" | grep -qE '^\+\+\+ b/.*\.py$'; then
  DETECTED_LANGS="$DETECTED_LANGS python"
fi
if echo "$PR_DIFF" | grep -qE '^\+\+\+ b/.*\.go$'; then
  DETECTED_LANGS="$DETECTED_LANGS go"
fi
if echo "$PR_DIFF" | grep -qE '^\+\+\+ b/.*\.php$'; then
  DETECTED_LANGS="$DETECTED_LANGS php"
fi

# 組合 patterns：base + 偵測到的語言
PATTERNS_DIR="$SCRIPT_DIR/patterns"
PATTERNS_CONTENT=$(cat "$PATTERNS_DIR/base.md")
for LANG in $DETECTED_LANGS; do
  if [ -f "$PATTERNS_DIR/${LANG}.md" ]; then
    PATTERNS_CONTENT="${PATTERNS_CONTENT}

$(cat "$PATTERNS_DIR/${LANG}.md")"
  fi
done

if [ -n "$DETECTED_LANGS" ]; then
  echo "   ✓ 偵測語言:${DETECTED_LANGS}"
else
  echo "   ✓ 使用通用 patterns"
fi

# 將 {{PATTERNS}} 替換為實際 patterns
PROMPT_TEMPLATE=$(cat "$PROMPT_FILE")
PROMPT_TEMPLATE="${PROMPT_TEMPLATE//\{\{PATTERNS\}\}/$PATTERNS_CONTENT}"

PROMPT_TMPFILE=$(mktemp)
cat > "$PROMPT_TMPFILE" <<EOF
${PROMPT_TEMPLATE}

## PR Metadata (JSON)
\`\`\`json
${PR_META}
\`\`\`

## PR Diff
\`\`\`diff
${PR_DIFF}
\`\`\`
EOF
echo "   ✓ 完成 $(step_time $STEP_START)"
echo ""

# Step 7: AI 分析（背景執行 + spinner）
echo "🤖 [3/3] AI 分析中..."
TMPFILE=$(mktemp)

run_ai "$ENGINE_CHOICE" "$PROMPT_TMPFILE" "$TMPFILE" &
spin $! "分析中"
rm -f "$PROMPT_TMPFILE"

# 總耗時
TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
TOTAL_MIN=$(( TOTAL_ELAPSED / 60 ))
TOTAL_SEC=$(( TOTAL_ELAPSED % 60 ))

# 讀取 token 用量
USAGE_FILE="${TMPFILE}.usage"
INPUT_TOKENS=$(jq -r '.input_tokens // 0' "$USAGE_FILE" 2>/dev/null)
OUTPUT_TOKENS=$(jq -r '.output_tokens // 0' "$USAGE_FILE" 2>/dev/null)
COST_USD=$(jq -r '.cost_usd // 0' "$USAGE_FILE" 2>/dev/null)
INPUT_TOKENS=${INPUT_TOKENS:-0}
OUTPUT_TOKENS=${OUTPUT_TOKENS:-0}
COST_USD=${COST_USD:-0}
rm -f "$USAGE_FILE"

case "$ENGINE_CHOICE" in
  4) ENGINE_NAME="API (${API_MODEL})" ;;
  *) ENGINE_NAME="${ENGINE_LABELS[$ENGINE_CHOICE]:-$ENGINE_CHOICE}" ;;
esac

{
  cat "$TMPFILE"
  printf "\n---\n"
  printf "Model: %s | Total: %02d:%02d | Tokens: %d in / %d out | Cost: \$%.4f\n" "$ENGINE_NAME" "$TOTAL_MIN" "$TOTAL_SEC" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$COST_USD"
  printf "<!-- verify-meta: repo=%s branch=%s -->\n" "$REPO" "$PR_HEAD_BRANCH"
} > "$FILENAME"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
awk '/^#+ *彙整表/,0' "$TMPFILE"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "✅ 完整報告已儲存至 ${SCRIPT_DIR}/${FILENAME}\n"
printf "⏱  總耗時 %02d:%02d\n" "$TOTAL_MIN" "$TOTAL_SEC"
printf "📊 Tokens: %'d in / %'d out | 費用: \$%.4f\n" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$COST_USD"
rm -f "$TMPFILE"

# Step 8: 檢查 🔴 問題，詢問是否驗證
BUG_COUNT=$(grep '統計' "$FILENAME" 2>/dev/null | grep -oE '🔴[^/]*' | grep -oE '[0-9]+' | head -1)
BUG_COUNT=${BUG_COUNT:-0}
if [ "$BUG_COUNT" -gt 0 ]; then
  echo ""
  echo "🔍 發現 ${BUG_COUNT} 個 🔴 BUG 級問題"
  read -r -p "是否進行深度驗證？ [Y/n]: " VERIFY
  VERIFY=${VERIFY:-Y}
  if [[ "$VERIFY" =~ ^[Yy]$ ]]; then
    # 傳遞引擎選擇給 verify-bug
    case "$ENGINE_CHOICE" in
      1|2) export PR_REVIEW_ENGINE=claude ;;
      3)   export PR_REVIEW_ENGINE=opencode ;;
      4)   export PR_REVIEW_ENGINE=api; export API_BASE API_KEY API_MODEL ;;
    esac
    bash "$SCRIPT_DIR/verify-bug.command" "$SCRIPT_DIR/$FILENAME"
    exit 0
  else
    echo "💡 稍後可執行: ./verify-bug.command $FILENAME"
  fi
else
  echo ""
  echo "✅ 沒有 🔴 BUG 級問題"
fi

echo ""
echo "按任意鍵關閉..."
read -n 1
