#!/bin/bash
# Test: App Platform deployment
# Verifies the app can be deployed to DigitalOcean App Platform using doctl

set -e

CONTAINER=${1:?Usage: $0 <container-name>}
source "$(dirname "$0")/../lib.sh"

SPEC_FILE="$(dirname "$0")/app-ssh-local.spec.yaml"
APP_ID=""

echo "Testing App Platform deployment..."

# Check for required environment variables (doctl action sets DIGITALOCEAN_ACCESS_TOKEN)
if [ -z "$DIGITALOCEAN_ACCESS_TOKEN" ]; then
    echo "error: DIGITALOCEAN_ACCESS_TOKEN not set (doctl not configured)"
    exit 1
fi

if [ -z "$TS_AUTHKEY" ]; then
    echo "error: TS_AUTHKEY not set (required for app deployment)"
    exit 1
fi

# Verify doctl is available
if ! command -v doctl &>/dev/null; then
    echo "error: doctl not installed"
    exit 1
fi

# Verify spec file exists
if [ ! -f "$SPEC_FILE" ]; then
    echo "error: Spec file not found: $SPEC_FILE"
    exit 1
fi

# Generate unique app name
APP_NAME="openclaw-ci-test-$(date +%s)-$$"
echo "App name: $APP_NAME"

# Get current branch for the deployment
CURRENT_BRANCH="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-main}}"
echo "Using branch: $CURRENT_BRANCH"

# Convert YAML spec to JSON and modify it
echo "Preparing app spec..."
APP_SPEC=$(yq -o=json "$SPEC_FILE" | jq \
    --arg name "$APP_NAME" \
    --arg branch "$CURRENT_BRANCH" \
    --arg ts_authkey "$TS_AUTHKEY" \
    --arg gateway_token "${OPENCLAW_GATEWAY_TOKEN:-test-token-$$}" \
    '
    .name = $name |
    .workers[0].name = $name |
    .workers[0].git.branch = $branch |
    .workers[0].envs = [
        .workers[0].envs[] |
        if .key == "TS_AUTHKEY" then .value = $ts_authkey
        elif .key == "OPENCLAW_GATEWAY_TOKEN" then .value = $gateway_token
        elif .key == "STABLE_HOSTNAME" then .value = $name
        else .
        end
    ]
    ')

echo "Creating app on App Platform..."
CREATE_OUTPUT=$(echo "$APP_SPEC" | doctl apps create --spec - --format ID --no-header 2>&1) || {
    echo "error: Failed to create app"
    echo "$CREATE_OUTPUT"
    exit 1
}

APP_ID=$(echo "$CREATE_OUTPUT" | head -1)
if [ -z "$APP_ID" ]; then
    echo "error: Failed to get app ID from creation output"
    echo "$CREATE_OUTPUT"
    exit 1
fi
echo "✓ Created app: $APP_ID"

# Output app ID for cleanup step
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "app_id=$APP_ID" >> "$GITHUB_OUTPUT"
fi

# Wait for app to be fully deployed (ACTIVE status)
echo "Waiting for app deployment (this may take several minutes)..."
DEPLOY_TIMEOUT=300  # 5 minutes
DEPLOY_START=$(date +%s)

while true; do
    ELAPSED=$(($(date +%s) - DEPLOY_START))
    APP_STATUS=$(doctl apps get "$APP_ID" --format ActiveDeployment.Phase --no-header 2>/dev/null || echo "UNKNOWN")
    echo "  [$ELAPSED s] Status: $APP_STATUS"

    case "$APP_STATUS" in
        ACTIVE)
            echo "✓ App deployed successfully"
            break
            ;;
        ERROR|CANCELED)
            echo "error: App deployment failed with status: $APP_STATUS"
            doctl apps logs "$APP_ID" --type=build 2>/dev/null | tail -50 || true
            exit 1
            ;;
    esac

    if [ $ELAPSED -ge $DEPLOY_TIMEOUT ]; then
        echo "error: Deployment timed out after ${DEPLOY_TIMEOUT}s"
        doctl apps logs "$APP_ID" --type=build 2>/dev/null | tail -50 || true
        exit 1
    fi
    sleep 10
done

# Get app info
echo ""
echo "App details:"
doctl apps get "$APP_ID" --format ID,DefaultIngress,ActiveDeployment.Phase 2>/dev/null || true

# Get component name for console access
COMPONENT_NAME=$(doctl apps get "$APP_ID" --format Spec.Workers[0].Name --no-header 2>/dev/null || echo "$APP_NAME")
echo "Component: $COMPONENT_NAME"

# Test app via console - verify SSH is running
echo ""
echo "Testing app via console..."
CONSOLE_OUTPUT=$(echo "pgrep -x sshd && echo SSH_RUNNING" | timeout 30 doctl apps console "$APP_ID" "$COMPONENT_NAME" 2>&1) || {
    echo "warning: Console test failed (non-critical)"
    echo "$CONSOLE_OUTPUT"
}

if echo "$CONSOLE_OUTPUT" | grep -q "SSH_RUNNING"; then
    echo "✓ SSH service verified running via console"
else
    echo "warning: Could not verify SSH via console"
fi

# Check logs for successful startup
echo ""
echo "Checking app logs..."
doctl apps logs "$APP_ID" --type=run 2>/dev/null | grep -E "(sshd|SSH|Started)" | tail -10 || true

echo ""
echo "App Platform deployment test passed (app will be cleaned up)"
