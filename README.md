# dsh-docker

Self-built Docker image for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`), using only DeepSeek's official npm package. No third-party wrapper code, no third-party image.

Why this repo exists: the upstream repo ships no Dockerfile and no official image, so any Docker image needs a packaging layer. Here that layer is three small files you can read in full:

- `Dockerfile` — base image `node:24`, installs only `@deepseek-ai/dsh` from npm. The version is not pinned: the workflow resolves npm's `latest` tag at build time.
- `entrypoint.sh` — about 20 lines. dsh refuses to bind `0.0.0.0`, so it runs on `127.0.0.1:3081` inside the container and `socat` forwards container port 3080 to it. Nothing else.
- `.github/workflows/docker-publish.yml` — GitHub Actions builds for `linux/amd64` + `linux/arm64` and pushes only to this repo's own GHCR, using the automatic `GITHUB_TOKEN`. No external secrets needed.

## Image

```
ghcr.io/linkkdon/dsh-docker:latest
```

The `latest` image always tracks the official upstream release: every build resolves npm's `latest` dist-tag for `@deepseek-ai/dsh` (currently `0.2.2-rc.1` as of 2026-11-12) and also tags the image with that exact version, e.g. `ghcr.io/linkkdon/dsh-docker:0.2.2-rc.1`.

Built automatically on every push to `main` and once a week on a schedule, so new upstream releases are picked up without a manual version bump. After the first publish, the package visibility was set to Public in the package settings.

## Run

```bash
docker run -d \
  --name deepseek-harness \
  --restart unless-stopped \
  -p 127.0.0.1:3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -v "$PWD/workspace:/workspace" \
  ghcr.io/linkkdon/dsh-docker:latest
```

Then open `http://127.0.0.1:3080`. Since dsh 0.2.0 the Web UI needs browser authentication: take the one-time `?token=` URL from the container log (`docker logs deepseek-harness`), open it once to exchange it for a session cookie, then use the UI normally.

To point dsh at a model provider other than DeepSeek's API, configure it in the Web UI under Settings → Models (for example an OpenAI-compatible endpoint such as your own New API gateway).

## Build locally

```bash
docker build -t dsh-docker:local .
```

## Upgrade the dsh version

No manual version bump is needed: the workflow resolves the upstream `latest` version on every run, and the weekly scheduled run rebuilds automatically when upstream moves. To build a specific version instead, run the workflow manually from the Actions tab and enter the version in the `dsh_version` input.

## Security notes

- Bind the host port to `127.0.0.1:3080` only. Do not expose it to the public internet or an untrusted LAN: dsh can execute commands inside the workspace.
- Only mount directories you allow the agent to read and write (`./workspace`).
- There is no `bwrap` sandbox inside the container. If a write task reports a sandbox error, switch the permission preset to `danger-full-access` in the Web UI — the container itself is the isolation boundary.
- The official dsh project is in developer preview and may introduce breaking changes.
