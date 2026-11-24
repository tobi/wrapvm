# wrapvm

A standalone desktop VM image for agents: one self-contained `Containerfile` (Arch Linux base, lazy `mise` toolchain, XFCE desktop, Google Chrome, and `voxl` viewer) that CI publishes as `ghcr.io/tobi/wrapvm:desktop`, plus a `Smolfile` and launcher script that boot it.

- Arch Linux base (x86_64 and ARM64) with `user` (uid/gid 1000, passwordless sudo) and lazy-installed `mise` runtimes under `/opt/mise`
- Xvfb `:1` + XFCE, viewed in a browser through [voxl](https://github.com/tembo/voxl) on 6080 (password; `wrap-desktop url` prints the link)
- one persistent Google Chrome with CDP on 9222 (9223 on guest interfaces)
- [agent-browser](https://github.com/vercel-labs/agent-browser) for browser use, attached to that Chrome
- [agent-desktop](https://github.com/vercel-labs/agent-desktop) for computer use, through AT-SPI
- `desktop` and `browser` skills in `~/.agents/skills`, pointing agents at those two CLIs' own guides
- sound: PulseAudio with a null sink, streamed by the viewer and recordable with ffmpeg
- the shared Chrome as the default browser (xdg-open, XFCE, `$BROWSER`), with its sandbox on
- ffmpeg
- a prompt that says `[vm:<machine>]` under smolvm, `[container:<host>]` in a container

`wrapvm` builds directly from `archlinux:latest` (or a custom `BASE_IMAGE`, such as a verified Arch Linux ARM rootfs on aarch64) with no external base image or CLI dependency. Guest paths (`/opt/wrap/bin/wrap-desktop`, `/etc/wrap/`, `WRAP_*` env vars) are kept as the stable runtime contract for Rune and existing machines.

## Files

| File | What |
| --- | --- |
| `Containerfile` | Standalone multi-stage VM definition (`base`, `voxl`, `desktop`). CI publishes `ghcr.io/tobi/wrapvm:desktop` (also `:latest`) |
| `Dockerfile` | A symlink to `Containerfile`, for `docker build .` |
| `resources/` | Global `mise.toml` (lazy runtimes) and `mise-desktop.toml` (agent CLIs) |
| `Smolfile` | A smolvm machine booting that image, with the workspace mount, network policy and credentials |
| `wrapvm` | One machine per directory: create, start, shell in (`wrapvm -- CMD` runs CMD) |
| `skills/` | The `desktop` and `browser` skills, installed into `~/.agents/skills` |
| `tests/` | Standalone source check, base/desktop toolchain, viewer, a11y, and integration tests |

## Use

```sh
./wrapvm                                  # smolvm: machine for $PWD, zsh in it; prints the viewer's sign-in link
docker run -d -p 127.0.0.1:6080:6080 ghcr.io/tobi/wrapvm:desktop   # or as a container
docker exec <id> wrap-desktop url         # its sign-in link
```

`WRAPVM_DESKTOP_PORT` picks another host port when `wrapvm` creates the machine.

## agent-browser config

`AGENT_BROWSER_CONFIG=/home/user/workspace/agent-browser.json` is set everywhere. When that file is
missing, `wrap-desktop start` and every login shell write `{"headed": true, "autoConnect": true}`; an
existing file is never touched. It replaces `~/.agent-browser/config.json`.

## Develop

```sh
make check                                # verify standalone Containerfile/workflow invariants
make test-base                            # build and test the base toolchain stage
make test                                 # podman build + tests; CONTAINER_ENGINE=docker works too
make image.tar && WRAPVM_IMAGE=$PWD/wrapvm.tar ./wrapvm   # boot a local build under smolvm
```
