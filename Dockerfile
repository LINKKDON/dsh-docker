# DeepSeek Harness - self-built image, official source only.
# No third-party wrapper code: dsh comes only from DeepSeek's own npm package.
# Official run method: npx @deepseek-ai/dsh web  (listens 127.0.0.1:3080)
# Upstream repo has no Dockerfile / official image, so this file is the
# only wrapper layer, and it lives in YOUR repo, under your control.
ARG DSH_VERSION=0.2.0-rc.2
FROM node:24-bookworm-slim

ARG DSH_VERSION
ENV DSH_VERSION=${DSH_VERSION} \
    DSH_HOME=/home/node/.dsh \
    DSH_INTERNAL_PORT=3081 \
    DSH_PORT=3080 \
    NODE_ENV=production

# Minimal runtime deps only: git + ripgrep are what dsh agents normally
# expect; socat is the TCP bridge (dsh refuses --host 0.0.0.0, so it
# stays on 127.0.0.1 inside the container and socat forwards 3080 -> 3081).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git ripgrep socat tini python3 \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable \
 && npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
 && npm cache clean --force \
 && mkdir -p /home/node/.dsh /workspace \
 && chown -R node:node /home/node/.dsh /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER node
WORKDIR /workspace
VOLUME ["/home/node/.dsh", "/workspace"]
EXPOSE 3080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["web"]
