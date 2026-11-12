# dsh-docker

Self-built Docker image for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`), using only DeepSeek's official npm package. No third-party wrapper code, no third-party image.

Why this repo exists: the upstream repo ships no Dockerfile and no official image, so any Docker image needs a packaging layer. Here that layer is five small files you can read in full:

| File | What it does |
|---|---|
| `Dockerfile` | `node:24-bookworm-slim` + `@deepseek-ai/dsh` from npm, plus the few runtime tools an agent expects. Version is not pinned: the workflow resolves npm's `latest` tag at build time. |
| `entrypoint.sh` | 94 lines of POSIX `sh`. dsh refuses to bind `0.0.0.0`, so it runs on `127.0.0.1:3081` inside the container and `socat` forwards container port `3080` to it. Also waits for the listener, fails fast if dsh dies early or the bridge cannot bind, passes `--public-url` so the printed token URL is the one your browser can actually open, and shuts the container down when dsh exits. |
| `docker-compose.yml` | The `docker run` line below as a compose file, with the loopback-only publish baked in. |
| `.dockerignore` | Keeps `.git`, `.github`, docs and the compose file out of the build context. |
| `.github/workflows/docker-publish.yml` | Builds `linux/amd64` + `linux/arm64` and pushes only to this repo's own GHCR, using the automatic `GITHUB_TOKEN`. No external secrets needed. |

## Image

```
ghcr.io/linkkdon/dsh-docker:latest
```

The `latest` image always tracks the official upstream release: every build resolves npm's `latest` dist-tag for `@deepseek-ai/dsh` (currently `0.2.2-rc.1`) and also tags the image with that exact version, e.g. `ghcr.io/linkkdon/dsh-docker:0.2.2-rc.1`. Every commit build also gets a `sha-<7 chars>` tag.

About npm dist-tags: `latest` is the release the dsh project recommends and the one `npx @deepseek-ai/dsh` installs — it is **not** necessarily the highest version number on the registry (`next` can hold a newer prerelease, e.g. `0.2.2-rc.2` while `latest` was still `0.2.2-rc.1`). This repo follows `latest` on purpose; to build something else, dispatch the workflow with an explicit version (see [Upgrade](#upgrade-the-dsh-version)).

Built automatically on every push to `main` and once a week on a schedule, so new upstream releases are picked up without a manual version bump. After the first publish, the package visibility was set to Public in the package settings.

## Run

```bash
mkdir -p ./workspace

docker run -d \
  --name deepseek-harness \
  --restart unless-stopped \
  -p 127.0.0.1:3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -v "$PWD/workspace:/workspace" \
  ghcr.io/linkkdon/dsh-docker:latest

docker logs deepseek-harness
```

The log contains a line like:

```
dsh web: http://127.0.0.1:3080/?token=…
```

**Open that URL as printed** — the port is already the host-facing one (`--public-url`), so nothing needs editing. It exchanges the launch token for a session cookie and drops you into the UI; afterwards plain `http://127.0.0.1:3080` works. The token belongs to the running dsh process, so re-read the log after a restart instead of reusing an old URL.

The same thing with compose:

```bash
mkdir -p ./workspace
docker compose up -d
docker compose logs -f
```

The container lives exactly as long as `dsh web` does. If dsh exits — at startup or later — the entrypoint tears the bridge down and the container exits with dsh's status, so `--restart unless-stopped` (or the compose `restart:` policy) can take over instead of leaving a running container with a dead UI. The image also ships a `HEALTHCHECK` that checks both hops: the bridged port must accept a connection *and* dsh behind it must return an HTTP response (any status, 401 included — a plain TCP connect is not enough, because `socat` accepts first and only then dials dsh).

To point dsh at a model provider other than DeepSeek's API, configure it in the Web UI under Settings → Models (for example an OpenAI-compatible endpoint such as your own New API gateway).

## Ports and the `127.0.0.1` requirement

Always publish to loopback: `-p 127.0.0.1:3080:3080`, never `-p 3080:3080`.

Two independent reasons:

1. dsh can execute commands in your workspace; an image port on `0.0.0.0` is reachable by the whole LAN or, behind a misconfigured firewall, the internet.
2. It does not even work. dsh's `/api` endpoints are guarded by a browser-trust fence that only accepts a `Host` that is (a) a loopback name, (b) the address dsh itself is bound to, or (c) an authority declared with `--trusted-host`. A LAN client sends `Host: 192.168.x.x:3080`, which is none of those, so the page loads but every API call returns **403**. "Localhost only" is the supported shape.

If you really need the fence widened, extra arguments after the default `web` are forwarded to dsh, so `--trusted-host` is reachable:

```bash
mkdir -p ./workspace

docker run -d --name deepseek-harness \
  -e DSH_PUBLIC_URL=http://192.168.1.50:3080/ \
  -p 192.168.1.50:3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -v "$PWD/workspace:/workspace" \
  ghcr.io/linkkdon/dsh-docker:latest web --trusted-host 192.168.1.50:3080
```

(`DSH_PUBLIC_URL` too, or the printed token URL keeps naming 127.0.0.1.) That only bypasses the fence — the port then serves anyone who can reach it — so prefer the SSH tunnel below.

Close and open it locally from a remote machine with SSH port forwarding:

```bash
ssh -L 3080:127.0.0.1:3080 you@docker-host
# then open http://127.0.0.1:3080 on your laptop
```

If you changed the **host** port (`-p 127.0.0.1:8080:3080`), tell dsh what the browser will use, otherwise the printed token URL names 3080 and its authority-scoped cookie is never read back:

```bash
-e DSH_PUBLIC_URL=http://127.0.0.1:8080/
```

## Configuration

Environment variables understood by the image:

| Variable | Default | Meaning |
|---|---|---|
| `DSH_PUBLIC_URL` | `http://127.0.0.1:${DSH_PORT}/` | The root dsh advertises: the printed token URL, the URL it would open, and the `DSH_WEB_URL` the agent sees. Set it whenever the browser-facing port/URL differs from the container port. Must be absolute `http(s)://host/`, no query or fragment. |
| `DSH_PORT` | `3080` | Container port `socat` listens on; this is what `EXPOSE`, `-p` and the first leg of the `HEALTHCHECK` refer to. Change it only together with `-p` and `DSH_PUBLIC_URL`. |
| `DSH_INTERNAL_PORT` | `3081` | Loopback port dsh itself listens on. Internal detail; leave alone. |
| `DSH_HOME` | `/home/node/.dsh` | dsh state directory (profiles, credentials, sessions). Back it with a volume. |
| `DSH_VERSION` | resolved at build time | **Informational only.** `-e DSH_VERSION=0.3.0` does not change the installed version — rebuild the image instead. `docker run --rm <image> --version` prints what is actually installed. |

## Workspace and file ownership (Linux)

The container runs as the unprivileged `node` user, **uid 1000**. A bind mount keeps the host directory's owner, so if `./workspace` belongs to your own uid (say 1001), the agent gets `EACCES` on every write — which is easy to misread as a sandbox problem. Either:

```bash
mkdir -p ./workspace && sudo chown -R 1000:1000 ./workspace
```

or run the container as yourself (`--user "$(id -u):$(id -g)"`). Note that the second option only works cleanly if you also point `DSH_HOME` at a directory that uid can write, since the state volume from the image is owned by 1000.

On macOS/Windows with Docker Desktop the bind mount is remapped and this does not apply.

## Sandbox

Inside the container dsh still applies its own command sandbox. On Linux the runner chain is **bubblewrap (`bwrap`) first, Landlock second**:

- The image installs `bubblewrap`, so the preferred runner is normally available.
- Docker's default seccomp/capability set can still refuse the namespace setup bubblewrap needs. dsh probes it functionally — it runs `true` under the real read-only profile and caches the answer — and, if that fails, falls back to **Landlock**. Landlock support arrives with the npm packages: `@deepseek-ai/node-addon-system` is a hard dependency of `dsh-sandbox-local` and declares prebuilt linux x64/arm64 artifacts. Whether those artifacts load in this image (glibc, architecture, kernel ≥ 5.13 that permits `landlock_*`) is only provable at run time, which is exactly what that fallback probe checks.
- Only when **both** runners probe unusable does a *sandboxed* preset give up: dsh throws `SANDBOX_UNAVAILABLE` — "no sandbox backend is usable on this host; refusing to run the command unconfined" — rather than silently running the command unsandboxed (the message comes from the `dsh-sandbox` provider, `lib/index.js`). Then you have two options: widen the container (`--security-opt seccomp=unconfined` or `--cap-add SYS_ADMIN` — both weaken the container boundary) or switch the permission preset to `danger-full-access` in the Web UI, accepting that the container itself is the only isolation.

Check the preferred runner without starting the UI:

```bash
docker exec deepseek-harness bwrap --ro-bind / / -- true; echo "bwrap exit=$?"
```

`exit=0` means bubblewrap works. A non-zero exit does not necessarily mean the sandbox is unavailable — dsh may just be using Landlock; confirm by running a write command in the UI.

## Build locally

```bash
docker build -t dsh-docker:local .
```

Then run it with the local tag in place of the published one:

```bash
docker run -d --name deepseek-harness --restart unless-stopped \
  -p 127.0.0.1:3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -v "$PWD/workspace:/workspace" \
  dsh-docker:local
```

The compose file can build instead of pull, but it needs the two commented lines in `docker-compose.yml` (`build: .` and `image: dsh-docker:local`) uncommented first, since a `build:` service that still names the GHCR image would retag a local build as the published one.

Build a specific upstream version:

```bash
docker build --build-arg DSH_VERSION=0.2.2-rc.2 -t dsh-docker:rc2 .
```

## Upgrade the dsh version

No manual version bump is needed: the workflow resolves the upstream `latest` version on every run, and the weekly scheduled run rebuilds automatically when upstream moves. To build a specific version instead, run the workflow manually from the Actions tab and enter the version in the `dsh_version` input. For an existing container:

```bash
docker pull ghcr.io/linkkdon/dsh-docker:latest
docker rm -f deepseek-harness   # state lives in the dsh-data volume; recreate with the same flags
```

## Troubleshooting

**The printed token URL points at a port nothing is listening on, or the browser says "connection refused".**
You changed the host port but not `DSH_PUBLIC_URL`. Add `-e DSH_PUBLIC_URL=http://127.0.0.1:<host-port>/` and restart.

**The page loads but every action fails with 403 / the UI looks empty.**
The container port is published on `0.0.0.0`, or you are reaching it through the host's LAN IP. Publish with `-p 127.0.0.1:3080:3080` and open `http://127.0.0.1:3080` (see [Ports](#ports-and-the-127001-requirement)).

**Container exits immediately after start.**
`docker logs deepseek-harness` will show either `dsh web exited during startup` (the real dsh error is printed just above it) or `dsh web did not listen on 127.0.0.1:3081 within 30s` (slow disk or emulated CPU, or something else holding the port). Nothing is masked into a "running but dead" container any more.

**`socat failed to listen on :3080`.**
Something inside the container already holds `DSH_PORT` (for example a `docker run … web --port 3080` that was forwarded on top of the bridge). The container exits at startup instead of serving a dead port; change `DSH_PORT` together with `-p` and `DSH_PUBLIC_URL`.

**Container exits by itself after the UI worked for a while.**
That is intended: the entrypoint supervises `dsh web`, so when dsh exits the container exits with it (`dsh exited (code N); shutting the bridge down` in the log) and your restart policy brings it back. A restart loop means dsh is crashing — read the error above that line.

**Container is reported `unhealthy` but the UI works.**
The `HEALTHCHECK` requires both `socat` on `$DSH_PORT` (3080) and an HTTP response from dsh on `$DSH_INTERNAL_PORT` (3081). If you changed either port inside the container without changing `-p` / `DSH_PUBLIC_URL`, the check and the publish disagree.

**`EACCES` / `Permission denied` when the agent writes to the workspace.**
File ownership on Linux — see [Workspace and file ownership](#workspace-and-file-ownership-linux).

**Agent commands fail with a sandbox error.**
See [Sandbox](#sandbox). Most cases are bubblewrap unavailable *and* Landlock unavailable on this kernel.

**`docker run -it <image> bash` should give me a shell.**
It does: `sh`/`bash` are passed through, `dsh web` is the default, and any other argument is handed to `dsh` (e.g. `--version`, or a headless task).

**The image is older than the npm `latest` I see.**
Scheduled builds run weekly. Trigger the workflow manually, or `docker pull` again.

## Security notes

- Bind the host port to `127.0.0.1:3080` only. Do not expose it to the public internet or an untrusted LAN: dsh can execute commands inside the workspace.
- Only mount directories you allow the agent to read and write (`./workspace`). The `/workspace` path is deliberately *not* a `VOLUME`, so an unmounted run cannot silently write into an anonymous volume.
- The container is the outermost boundary. Inside it, `danger-full-access` means exactly that for everything you mounted — use the sandboxed presets unless you need otherwise.
- The image runs as uid 1000 and is stopped through `tini`, so `docker stop` delivers `SIGTERM` to dsh and shuts down in well under the 10s grace period.
- The official dsh project is in developer preview and may introduce breaking changes.
