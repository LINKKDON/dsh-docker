# syntax=docker/dockerfile:1
# DeepSeek Harness - self-built image, official source only.
# No third-party wrapper code: dsh comes only from DeepSeek's own npm package.
# Official run method: npx @deepseek-ai/dsh web  (listens 127.0.0.1:3080)
# Upstream repo has no Dockerfile / official image, so this file is the
# only wrapper layer, and it lives in YOUR repo, under your control.
# Version is NOT pinned here: default `latest` follows the official
# npm dist-tag, i.e. whatever `npx @deepseek-ai/dsh` installs.
# The workflow resolves that tag to an exact version at build time
# and tags the image with it, so a rebuild always tracks upstream.
ARG DSH_VERSION=latest
FROM node:24-bookworm-slim

ARG DSH_VERSION
ENV DSH_VERSION=${DSH_VERSION} \
    DSH_HOME=/home/node/.dsh \
    DSH_INTERNAL_PORT=3081 \
    DSH_PORT=3080 \
    NODE_ENV=production \
    HOME=/home/node

# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      ripgrep \
      socat \
      tini \
      python3 \
      openssh-client \
      curl \
      jq \
      procps \
      less \
      unzip \
      patch \
 && rm -rf /var/lib/apt/lists/* \
 && git config --system --add safe.directory '*'

RUN npm install -g --no-audit --no-fund "@deepseek-ai/dsh@${DSH_VERSION}" pnpm@10 \
 && npm cache clean --force

ENV NPM_CONFIG_PREFIX=/home/node/.npm-global \
    PATH=/home/node/.npm-global/bin:$PATH

RUN mkdir -p /home/node/.dsh /workspace /home/node/.npm-global \
 && chown -R 1000:1000 /home/node/.dsh /workspace /home/node/.npm-global

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER 1000:1000
WORKDIR /workspace
VOLUME ["/home/node/.dsh", "/workspace"]
EXPOSE 3080

LABEL dsh.version="${DSH_VERSION}"

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3080/').then(r => process.exit(r.status < 500 ? 0 : 1)).catch(() => process.exit(1))"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["web"]
