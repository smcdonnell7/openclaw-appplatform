#!/bin/bash
set -e

# Ensure directories exist
mkdir -p "$CLAWDBOT_STATE_DIR" "$CLAWDBOT_WORKSPACE_DIR" "$CLAWDBOT_STATE_DIR/memory"

# Configure s3cmd for DO Spaces
configure_s3cmd() {
  cat > /tmp/.s3cfg << EOF
[default]
access_key = ${LITESTREAM_ACCESS_KEY_ID}
secret_key = ${LITESTREAM_SECRET_ACCESS_KEY}
host_base = ${SPACES_ENDPOINT}
host_bucket = %(bucket)s.${SPACES_ENDPOINT}
use_https = True
EOF
}

# Restore from Spaces backup if configured
if [ -n "$LITESTREAM_ACCESS_KEY_ID" ] && [ -n "$SPACES_BUCKET" ]; then
  echo "Restoring state from Spaces backup..."
  configure_s3cmd

  # Restore JSON state files (config, devices, sessions) via tar
  STATE_BACKUP_PATH="s3://${SPACES_BUCKET}/clawdbot/state-backup.tar.gz"
  if s3cmd -c /tmp/.s3cfg ls "$STATE_BACKUP_PATH" 2>/dev/null | grep -q state-backup; then
    echo "Downloading state backup..."
    s3cmd -c /tmp/.s3cfg get "$STATE_BACKUP_PATH" /tmp/state-backup.tar.gz && \
      tar -xzf /tmp/state-backup.tar.gz -C "$CLAWDBOT_STATE_DIR" || \
      echo "Warning: failed to restore state backup (continuing)"
    rm -f /tmp/state-backup.tar.gz
  else
    echo "No state backup found (first deployment)"
  fi

  # Restore SQLite memory database via Litestream
  echo "Restoring SQLite from Litestream..."
  litestream restore -if-replica-exists -config /etc/litestream.yml \
    "$CLAWDBOT_STATE_DIR/memory/main.sqlite" || true
fi

# Show version (image is rebuilt weekly with latest clawdbot)
echo "Clawdbot version: $(clawdbot --version 2>/dev/null || echo 'unknown')"

# Determine auth mode: password auth if SETUP_PASSWORD is set, otherwise token auth
if [ -n "$SETUP_PASSWORD" ]; then
  AUTH_MODE="password"
  AUTH_ARGS="--auth password --password \"\$SETUP_PASSWORD\""
  echo "Auth mode: password"
else
  # Generate a gateway token if not provided (required for LAN binding with token auth)
  if [ -z "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    export CLAWDBOT_GATEWAY_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '=/+' | head -c 32)
    echo "Generated gateway token (ephemeral)"
  fi
  AUTH_MODE="token"
  AUTH_ARGS="--token \"\$CLAWDBOT_GATEWAY_TOKEN\""
  echo "Auth mode: token"
fi

# Create config file for cloud deployment
# Dynamically generates config with Gradient provider if GRADIENT_API_KEY is set
# Note: Clawdbot uses moltbot.json as its config file name
CONFIG_FILE="$CLAWDBOT_STATE_DIR/moltbot.json"
DEFAULT_CONFIG="/data/.clawdbot/moltbot.default.json"

# Always regenerate config to avoid stale env var references from backups
echo "Creating config: $CONFIG_FILE"

# Start with base config from default file or create minimal one
  if [ -f "$DEFAULT_CONFIG" ]; then
    # Read default config but remove closing brace (we'll add it back after optional sections)
    sed '$ s/}$//' "$DEFAULT_CONFIG" > "$CONFIG_FILE"
  else
    # Minimal base config (without closing brace)
    cat > "$CONFIG_FILE" << 'CONFIGEOF'
{
  "gateway": {
    "mode": "local",
    "trustedProxies": ["0.0.0.0/0", "::/0"],
    "controlUi": {
      "allowInsecureAuth": true
    }
  }
CONFIGEOF
  fi

  # Conditionally add Gradient provider if API key is set
  if [ -n "$GRADIENT_API_KEY" ]; then
    echo "Adding Gradient provider to config"
    cat >> "$CONFIG_FILE" << GRADIENTEOF
,
  "models": {
    "mode": "merge",
    "providers": {
      "gradient": {
        "baseUrl": "https://inference.do-ai.run/v1",
        "apiKey": "$GRADIENT_API_KEY",
        "api": "openai-completions",
        "models": [
          {
            "id": "llama3.3-70b-instruct",
            "name": "Llama 3.3 70B Instruct",
            "reasoning": false,
            "input": ["text"],
            "contextWindow": 128000,
            "maxTokens": 8192
          },
          {
            "id": "anthropic-claude-4.5-sonnet",
            "name": "Claude 4.5 Sonnet",
            "reasoning": false,
            "input": ["text"],
            "contextWindow": 200000,
            "maxTokens": 8192
          },
          {
            "id": "anthropic-claude-opus-4.5",
            "name": "Claude Opus 4.5",
            "reasoning": true,
            "input": ["text"],
            "contextWindow": 200000,
            "maxTokens": 16384
          },
          {
            "id": "deepseek-r1-distill-llama-70b",
            "name": "DeepSeek R1 Distill Llama 70B",
            "reasoning": true,
            "input": ["text"],
            "contextWindow": 128000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "gradient/llama3.3-70b-instruct"
      }
    }
  }
GRADIENTEOF
  fi

# Close the JSON object
echo "}" >> "$CONFIG_FILE"

PORT="${PORT:-8080}"
echo "Starting gateway: port=$PORT bind=lan"

# Backup function for JSON state files
backup_state() {
  if [ -n "$LITESTREAM_ACCESS_KEY_ID" ] && [ -n "$SPACES_BUCKET" ]; then
    echo "Backing up state to Spaces..."
    cd "$CLAWDBOT_STATE_DIR"
    # Backup JSON files (exclude memory/ which Litestream handles)
    tar -czf /tmp/state-backup.tar.gz \
      --exclude='memory' \
      --exclude='*.sqlite*' \
      --exclude='*.db*' \
      --exclude='gateway.*.lock' \
      . 2>/dev/null || true

    # Upload to Spaces using s3cmd
    if [ -f /tmp/state-backup.tar.gz ]; then
      s3cmd -c /tmp/.s3cfg put /tmp/state-backup.tar.gz \
        "s3://${SPACES_BUCKET}/clawdbot/state-backup.tar.gz" && \
        echo "State backup uploaded" || \
        echo "Warning: state backup upload failed"
      rm -f /tmp/state-backup.tar.gz
    fi
  fi
}

# Background backup loop (every 5 minutes)
start_backup_loop() {
  while true; do
    sleep 300
    backup_state
  done
}

# Graceful shutdown handler
shutdown_handler() {
  echo "Shutting down, saving state..."
  backup_state
  exit 0
}
trap shutdown_handler SIGTERM SIGINT

# Start with or without Litestream replication
# Use same command format as fly.toml: gateway --allow-unconfigured --port X --bind lan
if [ -n "$LITESTREAM_ACCESS_KEY_ID" ] && [ -n "$SPACES_BUCKET" ]; then
  echo "Mode: Litestream + state backup enabled"

  # Start periodic backup in background
  start_backup_loop &

  # Run gateway with Litestream for SQLite replication
  # Use eval to properly expand AUTH_ARGS which contains quoted variables
  if [ "$AUTH_MODE" = "password" ]; then
    litestream replicate -config /etc/litestream.yml \
      -exec "clawdbot gateway --allow-unconfigured --port $PORT --bind lan --auth password --password \"$SETUP_PASSWORD\"" &
  else
    litestream replicate -config /etc/litestream.yml \
      -exec "clawdbot gateway --allow-unconfigured --port $PORT --bind lan --token $CLAWDBOT_GATEWAY_TOKEN" &
  fi
  GATEWAY_PID=$!

  # Wait for gateway and handle shutdown
  wait $GATEWAY_PID
else
  echo "Mode: ephemeral (no persistence)"
  if [ "$AUTH_MODE" = "password" ]; then
    exec clawdbot gateway --allow-unconfigured --port "$PORT" --bind lan --auth password --password "$SETUP_PASSWORD"
  else
    exec clawdbot gateway --allow-unconfigured --port "$PORT" --bind lan --token "$CLAWDBOT_GATEWAY_TOKEN"
  fi
fi
