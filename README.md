# wrapvm

A desktop VM for agents: [wrap](https://github.com/tobi/wrap)'s desktop image, as one
`Containerfile` that CI publishes as `ghcr.io/tobi/wrapvm:desktop` and a `Smolfile` that boots it.

- Xvfb `:1` + XFCE, viewed in a browser through [voxl](https://github.com/tembo/voxl) on 6080 (password; `wrap-desktop url` prints the link)
- one persistent browser with CDP on 9222 (9223 on guest interfaces): Google Chrome on amd64, Chromium on arm64
- [agent-browser](https://github.com/vercel-labs/agent-browser) for browser use, attached to that Chrome
- [agent-desktop](https://github.com/vercel-labs/agent-desktop) for computer use, through AT-SPI
- `desktop` and `browser` skills in `~/.agents/skills`, pointing agents at those two CLIs' own guides
- sound: PulseAudio with a null sink, streamed by the viewer and recordable with ffmpeg
- the shared Chrome as the default browser (xdg-open, XFCE, `$BROWSER`), with its sandbox on
- ffmpeg
- a prompt that says `[vm:<machine>]` under smolvm, `[container:<host>]` in a container

The `Containerfile` is tobi/wrap's `Containerfile.desktop` at `c562a7d`, plus what wrapvm adds (each block is
marked `wrapvm:`). wrap keeps the CLI and the base image (`ghcr.io/tobi/wrap:latest`, the `FROM` here).

## Files

| File | What |
| --- | --- |
| `Containerfile` | The VM. CI builds it, tests it and publishes `ghcr.io/tobi/wrapvm:desktop` (also `:latest`) |
| `Dockerfile` | A symlink to `Containerfile`, for `docker build .` |
| `Smolfile` | A smolvm machine booting that image, with the workspace mount, network policy and credentials |
| `wrapvm` | One machine per directory: create, start, shell in (`wrapvm -- CMD` runs CMD) |
| `skills/` | The `desktop` and `browser` skills, installed into `~/.agents/skills` |
| `tests/` | wrap's desktop tests and `container_wrapvm.sh`; run by CI and `make test` |

## Use

```sh
./wrapvm                                  # smolvm: machine for $PWD, zsh in it; prints the viewer's sign-in link
docker run -d -p 127.0.0.1:6080:6080 ghcr.io/tobi/wrapvm:desktop   # or as a container
docker exec <id> wrap-desktop url         # its sign-in link
```

`WRAPVM_DESKTOP_PORT` picks another host port when `wrapvm` creates the machine.

## arm64

The same `Containerfile` builds both architectures. On arm64 the shared browser is Arch Linux ARM's
Chromium, because Google publishes no linux-arm64 Chrome; the amd64 build cannot stand in, since it
dies under qemu-user emulation before CDP comes up. Chromium is the same engine, so CDP, the managed
policies, `agent-browser`'s `autoConnect` and the dock all work as on amd64; it has no Widevine and
no Google auto-update.

`ghcr.io/tobi/wrap:latest` is amd64-only, so the base comes from tobi/wrap's `Containerfile.arm64`:

```sh
git clone https://github.com/tobi/wrap && cd wrap && git checkout c562a7d   # the base wrapvm is built on
docker buildx build --platform linux/arm64 --load -f Containerfile.arm64 -t wrap-arm64:local .
cd - && make test CONTAINER_ENGINE=docker BASE_IMAGE=wrap-arm64:local
docker buildx build --platform linux/arm64 --load --build-arg BASE_IMAGE=wrap-arm64:local \
  -t wrapvm:arm64 .
```

CI builds and tests arm64 on a native arm64 runner; it does not publish it (that needs an arm64
base published from tobi/wrap, plus a manifest merge).

## agent-browser config

`AGENT_BROWSER_CONFIG=/home/user/workspace/agent-browser.json` is set everywhere. When that file is
missing, `wrap-desktop start` and every login shell write `{"headed": true, "autoConnect": true}`; an
existing file is never touched. It replaces `~/.agent-browser/config.json`.

## Develop

```sh
make test                                 # podman build + tests; CONTAINER_ENGINE=docker works too
make image.tar && WRAPVM_IMAGE=$PWD/wrapvm.tar ./wrapvm   # boot a local build under smolvm
```
