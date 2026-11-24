# wrapvm

- `Containerfile` is the single standalone definition of the VM (Arch base + mise toolchain + desktop + voxl viewer). `Dockerfile` is a symlink to it; never fork them.
  The `Smolfile` only boots the published image (`ghcr.io/tobi/wrapvm:desktop`): settings that exist only at run time (mounts, network policy, credentials, resources) go there; everything about the guest goes in the Containerfile.
- `wrapvm` has no dependency on `tobi/wrap` or `ghcr.io/tobi/wrap`. Guest paths under `/opt/wrap`, `/etc/wrap`, `/var/lib/wrap-desktop` and `WRAP_*` environment variables remain stable as the runtime compatibility contract for Rune and existing VMs.
- Scripts are written with `RUN cat > … <<'EOF'`; build with BuildKit or podman, never Docker's legacy builder.
- Keep agent-desktop working: no `NO_AT_BRIDGE`, `wrap-a11y` on in `wrap-desktop start`, no xfwm4 compositing.
  Run `make check` and `make test` (and `make test-base` when touching the base stage) after changing the image.
- Build steps run as root with `HOME=/root`; nothing may leave root-owned files under `/opt/mise` or `/home/user`.
