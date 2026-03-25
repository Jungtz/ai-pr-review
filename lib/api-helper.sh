#!/bin/bash
# Shared API helper functions for bash scripts
# Usage: source "$SCRIPT_DIR/lib/api-helper.sh"

# ── API Config Cache ──────────────────────────────────────

# Load API config from cache file. Sets CACHED_BASE, CACHED_KEY, CACHED_MODEL.
# Usage: load_api_config "$SCRIPT_DIR/.api-config"
load_api_config() {
  local config_file="$1"
  CACHED_BASE="" ; CACHED_KEY="" ; CACHED_MODEL=""
  if [ -f "$config_file" ]; then
    CACHED_BASE=$(grep '^API_BASE=' "$config_file" | cut -d= -f2-)
    CACHED_KEY=$(grep '^API_KEY=' "$config_file" | cut -d= -f2-)
    CACHED_MODEL=$(grep '^API_MODEL=' "$config_file" | cut -d= -f2-)
  fi
  CACHED_BASE=${CACHED_BASE:-http://localhost:11434/v1}
  CACHED_MODEL=${CACHED_MODEL:-llama3}
}

# Save API config to cache file.
# Usage: save_api_config "$SCRIPT_DIR/.api-config" "$API_BASE" "$API_KEY" "$API_MODEL"
save_api_config() {
  local config_file="$1"
  cat > "$config_file" <<EOF
API_BASE=${2}
API_KEY=${3}
API_MODEL=${4}
EOF
}

# ── API Key Masking ───────────────────────────────────────

# Mask an API key for display: "sk-proj-abc...wxyz" or "(none)"
# Usage: mask_key "$API_KEY"
mask_key() {
  local key="$1"
  if [ -z "$key" ]; then
    echo "(none)"
  elif [ ${#key} -le 8 ]; then
    echo "****"
  else
    echo "${key:0:4}...${key: -4}"
  fi
}

# ── Prompt API for settings ───────────────────────────────

# Interactive prompt for API settings with cached defaults.
# Sets API_BASE, API_KEY, API_MODEL.
# Usage: prompt_api_settings "$SCRIPT_DIR/.api-config"
prompt_api_settings() {
  local config_file="$1"
  load_api_config "$config_file"

  local masked
  masked=$(mask_key "$CACHED_KEY")

  read -r -p "API Base URL [${CACHED_BASE}]: " API_BASE
  API_BASE=${API_BASE:-$CACHED_BASE}
  read -r -p "API Key [${masked}]: " API_KEY
  API_KEY=${API_KEY:-$CACHED_KEY}
  read -r -p "Model 名稱 [${CACHED_MODEL}]: " API_MODEL
  API_MODEL=${API_MODEL:-$CACHED_MODEL}

  save_api_config "$config_file" "$API_BASE" "$API_KEY" "$API_MODEL"
}

# ── Call OpenAI-compatible API ────────────────────────────

# Call an OpenAI-compatible chat completions API.
# Reads prompt from $prompt_file, writes result to $output_file,
# writes usage JSON to ${output_file}.usage.
#
# Usage: run_api "$api_base" "$api_key" "$model" "$prompt_file" "$output_file"
run_api() {
  local api_base="$1"
  local api_key="$2"
  local model="$3"
  local prompt_file="$4"
  local output_file="$5"
  local raw_file="${output_file}.raw"
  local api_url="${api_base}/chat/completions"

  # Build JSON payload safely with jq
  jq -Rs --arg model "$model" \
    '{model: $model, messages: [{role: "user", content: .}]}' \
    "$prompt_file" > "${raw_file}.req"

  # Build curl args as array (no eval needed)
  local curl_args=(-s "$api_url" -H "Content-Type: application/json" -d @"${raw_file}.req")
  if [ -n "$api_key" ]; then
    curl_args+=(-H "Authorization: Bearer ${api_key}")
  fi

  curl "${curl_args[@]}" > "$raw_file"
  local curl_exit=$?

  # Error handling
  if [ $curl_exit -ne 0 ]; then
    echo "❌ API 連線失敗 (curl exit code: ${curl_exit})" >&2
    echo "API 連線失敗" > "$output_file"
    echo '{}' > "${output_file}.usage"
    rm -f "$raw_file" "${raw_file}.req"
    return 1
  fi

  # Check for API error response
  local api_error
  api_error=$(jq -r '.error.message // empty' "$raw_file" 2>/dev/null)
  if [ -n "$api_error" ]; then
    echo "❌ API 錯誤: ${api_error}" >&2
    echo "API 錯誤: ${api_error}" > "$output_file"
    echo '{}' > "${output_file}.usage"
    rm -f "$raw_file" "${raw_file}.req"
    return 1
  fi

  # Extract content
  jq -r '.choices[0].message.content // empty' "$raw_file" > "$output_file"

  # Extract usage
  jq '{input_tokens: (.usage.prompt_tokens // 0), output_tokens: (.usage.completion_tokens // 0), cache_creation: 0, cache_read: 0, cost_usd: 0}' \
    "$raw_file" > "${output_file}.usage" 2>/dev/null

  rm -f "$raw_file" "${raw_file}.req"
  return 0
}
