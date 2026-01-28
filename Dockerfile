FROM node:24-slim AS builder

# Install pnpm and build dependencies
RUN npm install -g pnpm@10

WORKDIR /build

# Clone and build Clawdbot from source
ARG CLAWDBOT_REPO=https://github.com/clawdbot/clawdbot.git
ARG CLAWDBOT_REF=main

ENV CI=true

RUN apt-get update && apt-get install -y git && \
    git clone --depth 1 --branch ${CLAWDBOT_REF} ${CLAWDBOT_REPO} . && \
    pnpm install --frozen-lockfile && \
    pnpm build && \
    pnpm ui:build && \
    pnpm prune --prod

# --- Final image ---
FROM node:24-slim

ARG TARGETARCH
ARG LITESTREAM_VERSION=0.5.6

ENV PORT=8080 \
    CLAWDBOT_STATE_DIR=/data/.clawdbot \
    CLAWDBOT_WORKSPACE_DIR=/data/workspace \
    NODE_ENV=production

# Install OS deps + Litestream + s3cmd for state backup
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        curl \
        openssl \
        git \
        s3cmd \
        python3; \
    LITESTREAM_ARCH="$( [ "$TARGETARCH" = "arm64" ] && echo arm64 || echo x86_64 )"; \
    wget -O /tmp/litestream.deb \
      https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${LITESTREAM_ARCH}.deb; \
    dpkg -i /tmp/litestream.deb; \
    rm /tmp/litestream.deb; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Copy built Clawdbot from builder (only what's needed)
COPY --from=builder /build/dist /usr/local/lib/clawdbot/dist
COPY --from=builder /build/node_modules /usr/local/lib/clawdbot/node_modules
COPY --from=builder /build/package.json /usr/local/lib/clawdbot/package.json
COPY --from=builder /build/extensions /usr/local/lib/clawdbot/extensions
COPY --from=builder /build/skills /usr/local/lib/clawdbot/skills

# Create clawdbot executable wrapper
RUN echo '#!/bin/sh' > /usr/local/bin/clawdbot && \
    echo 'exec node /usr/local/lib/clawdbot/dist/entry.js "$@"' >> /usr/local/bin/clawdbot && \
    chmod +x /usr/local/bin/clawdbot

# Create non-root user with home directory
RUN useradd -r -u 10001 -m -d /home/clawdbot clawdbot \
    && mkdir -p /data/.clawdbot /data/workspace \
    && chown -R clawdbot:clawdbot /data /home/clawdbot

# Copy default config with App Platform settings (moltbot.json is the actual config file name)
COPY moltbot.default.json /data/.clawdbot/moltbot.default.json
RUN chown clawdbot:clawdbot /data/.clawdbot/moltbot.default.json

COPY entrypoint.sh /entrypoint.sh
COPY litestream.yml /etc/litestream.yml
RUN chmod +x /entrypoint.sh

EXPOSE 8080

USER clawdbot
ENTRYPOINT ["/entrypoint.sh"]
