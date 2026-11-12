# dsh-docker

Self-built Docker image for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`), using only DeepSeek's official npm package. No third-party wrapper code, no third-party image.

Why this repo exists: the upstream repo ships no Dockerfile and no official image, so any Docker image needs a packaging layer. Here that layer is three small files you can read in full:

- `Dockerfile` — base image `node:24`, installs DeepSeek's official `@deepseek-ai/dsh` package plus `pnpm` for plugin management. No third-party wrapper code. The dsh version is not pinned: the workflow resolves npm's `latest` dist-tag at build time.
- `entrypoint.sh` — dsh refuses to bind `0.0.0.0`, so it listens on `127.0.0.1:3081` inside the container, `socat` runs in background forwarding port 3080, and dsh runs in foreground so the container exits when dsh exits.
- `.github/workflows/docker-publish.yml` — GitHub Actions builds for `linux/amd64` + `linux/arm64` and pushes only to this repo's own GHCR, using the automatic `GITHUB_TOKEN`. No external secrets needed.

## Image

```
ghcr.io/linkkdon/dsh-docker:latest
```

The `latest` tag always tracks npm's `latest` dist-tag for `@deepseek-ai/dsh`. It may lag behind `next` (currently `next=0.2.2-rc.2`). Every build also tags the image with the exact resolved version, e.g. `ghcr.io/linkkdon/dsh-docker:0.2.2-rc.1`.

Built automatically on every push to `main` and once a week on a schedule, so new upstream releases are picked up without a manual version bump. After the first publish, the package visibility was set to Public in the package settings.

## Run

```bash
mkdir -p workspace
docker run -d \
  --name deepseek-harness \
  --restart unless-stopped \
  -p 127.0.0.1:3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -v "$PWD/workspace:/workspace" \
  ghcr.io/linkkdon/dsh-docker:latest
```

Then open `http://127.0.0.1:3080`. Since dsh 0.2.0 the Web UI needs browser authentication: take the `?token=` URL from the container log (`docker logs deepseek-harness`) and open it to exchange the token for a session cookie. The token remains valid for the dsh process lifetime (a container restart generates a new one). The old token remains in `docker logs` after a restart but is no longer valid; treat container logs as credentials.

If you map the host to a different port (e.g. `-p 127.0.0.1:8080:3080`), set `DSH_PUBLIC_URL` so the token URL matches:

```bash
docker run -d \
  -p 127.0.0.1:8080:3080 \
  -e DSH_PUBLIC_URL=http://127.0.0.1:8080/ \
  ...
```

To point dsh at a model provider other than DeepSeek's API, configure it in the Web UI under Settings → Models (for example an OpenAI-compatible endpoint such as your own New API gateway).

## Build locally

```bash
docker build -t dsh-docker:local .
```

## Upgrade the dsh version

No manual version bump is needed: the workflow resolves the upstream `latest` version on every run, and the weekly scheduled run rebuilds automatically when upstream moves. To build a specific version instead, run the workflow manually from the Actions tab and enter the version in the `dsh_version` input.

## Security notes

- Bind the host port to `127.0.0.1:3080` only. Do not expose it to the public internet or an untrusted LAN: dsh agents can execute arbitrary commands in the entire container, not just the workspace.
- Only mount directories you allow the agent to read and write. The agent can read and write the entire `/workspace` mount and all of `/home/node/.dsh`.
- The `danger-full-access` permission preset allows reading `/home/node/.dsh` (which may contain credentials) and unrestricted network access. Use it only when a task reports `SANDBOX_UNAVAILABLE`.
- Other containers on the same Docker network can access port 3080. Use separate networks or firewall rules if multi-tenancy is required.
- Consider restricting outbound network access with Docker's `--network` options or external firewall rules.
- `bwrap` is not installed in the image. dsh may fall back to Landlock (full or partial enforcement depending on kernel capabilities). If no sandbox runner is available, the task will fail with `SANDBOX_UNAVAILABLE`. Only switch to `danger-full-access` when that error occurs, not for routine operation.
- The official dsh project is in developer preview and may introduce breaking changes.
