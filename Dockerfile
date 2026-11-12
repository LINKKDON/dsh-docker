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

# Redeclared after FROM: an ARG is only visible inside the stage that declares it.
ARG DSH_VERSION
# NODE_ENV is deliberately NOT set: every process in the container inherits it,
# including the agent's own `npm install` inside /workspace, where
# NODE_ENV=production silently skips devDependencies.
# DSH_PORT / DSH_INTERNAL_PORT are container-internal wiring consumed by
# entrypoint.sh (and by the HEALTHCHECK); publishing a different HOST port is
# done with `-p` plus DSH_PUBLIC_URL, not by changing these.
ENV DSH_VERSION=${DSH_VERSION} \
    DSH_HOME=/home/node/.dsh \
    DSH_INTERNAL_PORT=3081 \
    DSH_PORT=3080

# ca-certificates: TLS to the model API.
# git, ripgrep: what the agent's shell normally expects to find.
# socat: the TCP bridge (dsh refuses --host 0.0.0.0, so it stays on 127.0.0.1
#        inside the container and socat forwards 3080 -> 3081).
# tini: PID 1 duties (reaping + signal forwarding, see ENTRYPOINT).
# bubblewrap: the preferred sandbox runner. Where the kernel or the container
#        refuses it, dsh falls back to Landlock: @deepseek-ai/node-addon-system
#        is a hard dependency of dsh-sandbox-local and declares prebuilt
#        linux x64/arm64 artifacts. Only when both runners probe unusable does a
#        sandboxed task fail; the fallback then is the danger-full-access preset.
# python3: not needed by `dsh web` itself, but the Python PTC runtime and the
#        agent's own workspace scripts expect an interpreter to exist.
# Install tools are removed afterwards to keep the layer small.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bubblewrap ca-certificates git python3 ripgrep socat tini \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable \
 && npm install -g --no-fund --no-audit "@deepseek-ai/dsh@${DSH_VERSION}" \
 && npm cache clean --force \
 && mkdir -p /home/node/.dsh /workspace \
 && chown -R node:node /home/node/.dsh /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER node
WORKDIR /workspace
# Only the dsh state directory is declared as a volume. /workspace is meant to
# be bind-mounted by the user; as a VOLUME it would silently capture anything
# written without -v into an anonymous volume.
VOLUME ["/home/node/.dsh"]
EXPOSE 3080

# Probe both hops, not just the bridge: socat accepts a connection first and
# only then dials dsh, so a bare TCP connect to $DSH_PORT still succeeds when
# dsh is dead. The check therefore also demands an HTTP response (any status,
# 401 included) from $DSH_INTERNAL_PORT. start-period covers a cold start on a
# slow or emulated host; entrypoint.sh fails fast on its own.
HEALTHCHECK --interval=30s --timeout=6s --start-period=30s --retries=3 \
  CMD node -e 'const net=require("net"),http=require("http");const p1=+(process.env.DSH_PORT||3080),p2=+(process.env.DSH_INTERNAL_PORT||3081);const t=setTimeout(()=>process.exit(1),5000);net.connect(p1,"127.0.0.1").on("connect",function(){this.end();http.get({host:"127.0.0.1",port:p2,path:"/",timeout:4000},function(r){r.resume();clearTimeout(t);process.exit(0)}).on("error",()=>process.exit(1))}).on("error",()=>process.exit(1))'

# -g: forward signals to the whole process group. Without it the `dsh web`
# background process never sees SIGTERM and `docker stop` waits out the full
# grace period before SIGKILL.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["web"]
