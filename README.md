# Clawdbot App Platform Image

Pre-built Docker image for deploying [Clawdbot](https://github.com/clawdbot/clawdbot) on DigitalOcean App Platform.

[![Deploy to DO](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/apps/new?repo=https://github.com/digitalocean-labs/clawdbot-appplatform/tree/main)

## Features

- **Fast boot** (~30 seconds)
- **Built from source** with latest features (device auth bypass, Gradient AI)
- **Pre-configured** for App Platform (trusted proxies, Control UI access)
- **Optional persistence** via Litestream + DO Spaces
- **Multi-arch** support (amd64/arm64)

## Quick Start

1. Click the **Deploy to DO** button above
2. Set `SETUP_PASSWORD` when prompted
3. Wait for deployment (~1 minute)
4. Open `https://<your-app>.ondigitalocean.app/setup` to complete setup

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│           GHCR Image: ghcr.io/bikramkgupta/                 │
│                    clawdbot-appplatform                          │
│  ┌───────────┐  ┌───────────┐  ┌────────────────────────────┐   │
│  │ Node 24   │  │ Clawdbot  │  │ Litestream (optional)      │   │
│  │ (slim)    │  │ (latest)  │  │ SQLite → DO Spaces backup  │   │
│  └───────────┘  └───────────┘  └────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

## Environment Variables

### Required

| Variable | Description |
|----------|-------------|
| `SETUP_PASSWORD` | Password for the web setup wizard |

### Recommended

| Variable | Description |
|----------|-------------|
| `CLAWDBOT_GATEWAY_TOKEN` | Admin token for gateway API access |

### Optional (Model Provider)

| Variable | Description |
|----------|-------------|
| `GRADIENT_API_KEY` | DigitalOcean Gradient AI Model Access Key for serverless inference |

See [Gradient AI Setup](#gradient-ai-setup) for configuration details.

### Optional (Persistence)

Without these, the app runs in ephemeral mode - state is lost on redeploy.

| Variable | Description | Example |
|----------|-------------|---------|
| `LITESTREAM_ACCESS_KEY_ID` | DO Spaces access key | |
| `LITESTREAM_SECRET_ACCESS_KEY` | DO Spaces secret key | |
| `SPACES_ENDPOINT` | Spaces endpoint | `tor1.digitaloceanspaces.com` |
| `SPACES_BUCKET` | Spaces bucket name | `my-clawdbot-backup` |

## Resource Requirements

| Resource | Value |
|----------|-------|
| CPU | 1 shared vCPU |
| RAM | 2 GB |
| Instance | `apps-s-1vcpu-2gb` |
| Cost | ~$25/mo (+ $5/mo Spaces optional) |

> **Note:** The gateway requires 2GB RAM to start reliably. Using `basic-xs` (1GB) will result in OOM errors.

## Available Regions

- `nyc` - New York
- `ams` - Amsterdam
- `sfo` - San Francisco
- `sgp` - Singapore
- `lon` - London
- `fra` - Frankfurt
- `blr` - Bangalore
- `syd` - Sydney
- `tor` - Toronto (default)

Edit the `region` field in `app.yaml` to change.

## Manual Deployment

```bash
# Clone and deploy
git clone https://github.com/digitalocean-labs/clawdbot-appplatform
cd clawdbot-appplatform

# Validate spec
doctl apps spec validate app.yaml

# Create app
doctl apps create --spec app.yaml

# Set secrets in the DO dashboard
```

## Setting Up Persistence

App Platform doesn't have persistent volumes, so this image uses DO Spaces for state backup.

### What Gets Persisted

| Data Type | Backup Method | Description |
|-----------|--------------|-------------|
| Memory search index | Litestream (real-time) | SQLite database for vector search |
| Config, devices, sessions | S3 backup (every 5 min) | JSON state files |

### Setup Steps

1. **Create a Spaces bucket** in the same region as your app
   - Go to **Spaces Object Storage** → **Create Bucket**
   - Name: e.g., `clawdbot-backup`
   - Region: match your app (e.g., `tor1` for Toronto)

2. **Create Spaces access keys**
   - Go to **Settings → API → Spaces Keys**
   - Click **Generate New Key**
   - Save both Access Key and Secret Key

3. **Add environment variables** to your App Platform app:
   - `LITESTREAM_ACCESS_KEY_ID` = your access key
   - `LITESTREAM_SECRET_ACCESS_KEY` = your secret key
   - `SPACES_ENDPOINT` = `<region>.digitaloceanspaces.com` (e.g., `tor1.digitaloceanspaces.com`)
   - `SPACES_BUCKET` = your bucket name

4. **Redeploy** the app

### How It Works

On startup:
1. Restores JSON state backup from Spaces (if exists)
2. Restores SQLite memory database via Litestream (if exists)
3. Starts the gateway

During operation:
- Litestream continuously replicates SQLite changes (1s sync interval)
- JSON state is backed up every 5 minutes
- On graceful shutdown (SIGTERM), final state backup is saved

## Control UI Access

The image comes pre-configured with password authentication mode and `trustedProxies: ["0.0.0.0/0"]`. This is necessary because App Platform runs behind Cloudflare's reverse proxy.

Access the Control UI at:
```
https://<your-app>.ondigitalocean.app/
```

You'll be prompted to enter your `SETUP_PASSWORD` to authenticate.

> **Security Note:** The password is your `SETUP_PASSWORD` environment variable. Keep it secret. HTTPS is provided by App Platform via Cloudflare.

## Gradient AI Setup

[DigitalOcean Gradient](https://www.digitalocean.com/products/gradient) provides serverless AI inference with models like Llama 3.3, Claude, and GPT-4o. To use Gradient as your model provider:

### 1. Create a Model Access Key

1. Go to [Gradient Serverless Inference](https://cloud.digitalocean.com/gen-ai/serverless-inference)
2. Click **Create model access key**
3. Name it (e.g., `clawdbot`) and save the secret key

Or via API:
```bash
curl -X POST "https://api.digitalocean.com/v2/gen-ai/models/api_keys" \
  -H "Authorization: Bearer $DIGITALOCEAN_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "clawdbot"}'
```

### 2. Add Environment Variable

Add `GRADIENT_API_KEY` to your App Platform app (as a secret).

### 3. Done

The image comes pre-configured for Gradient AI with `llama3.3-70b-instruct` as the default model. No additional configuration needed.

The default config (`clawdbot.default.json`) includes:
- Gradient provider at `https://inference.do-ai.run/v1`
- API key via `${GRADIENT_API_KEY}` environment variable
- Default model: `gradient/llama3.3-70b-instruct`

### Available Models

| Model ID | Description |
|----------|-------------|
| `llama3.3-70b-instruct` | Meta Llama 3.3 70B (general purpose) |
| `llama3-8b-instruct` | Meta Llama 3 8B (faster, lower cost) |
| `anthropic-claude-opus-4` | Claude Opus 4 |
| `anthropic-claude-sonnet-4` | Claude Sonnet 4 |
| `openai-gpt-4o` | GPT-4o |

Run `doctl genai list-models` or check the [Gradient dashboard](https://cloud.digitalocean.com/gen-ai/serverless-inference) for the full list.

## Documentation

- [Full deployment guide](https://docs.clawd.bot/digitalocean)
- [Clawdbot documentation](https://docs.clawd.bot)
- [Gradient AI documentation](https://docs.digitalocean.com/products/gradient-ai-platform/)

## License

MIT
