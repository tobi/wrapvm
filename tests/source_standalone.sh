#!/bin/bash
# Static check: wrapvm must build standalone without tobi/wrap or ghcr.io/tobi/wrap.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ok() { printf 'ok - %s
' "$*"; }
die() { printf 'FAIL - %s
' "$*" >&2; exit 1; }

[ -L "$root/Dockerfile" ] && [ "$(readlink "$root/Dockerfile")" = Containerfile ]   || die 'Dockerfile must remain a symlink to Containerfile'
ok 'Dockerfile symlinks to Containerfile'

[ -f "$root/resources/mise.toml" ] || die 'missing resources/mise.toml'
[ -f "$root/resources/mise-desktop.toml" ] || die 'missing resources/mise-desktop.toml'
ok 'both mise config files live in resources/'

grep -qx 'ARG BASE_IMAGE=archlinux:latest' "$root/Containerfile"   || die 'Containerfile default BASE_IMAGE must be archlinux:latest'
grep -qx 'FROM ${BASE_IMAGE} AS base' "$root/Containerfile"   || die 'Containerfile must define stage base from BASE_IMAGE'
grep -qx 'FROM base AS voxl' "$root/Containerfile"   || die 'voxl stage must build from internal base stage'
grep -qx 'FROM base AS desktop' "$root/Containerfile"   || die 'desktop stage must build from internal base stage'
ok 'Containerfile defines self-contained base, voxl, and desktop stages'

if grep -En 'ghcr.io/tobi/wrap|github.com/tobi/wrap|tobi/wrap|Containerfile.desktop'   "$root/Containerfile" "$root/Makefile" "$root/.github/workflows/image.yml" "$root/Smolfile" "$root/wrapvm"; then
  die 'found leftover external dependency on tobi/wrap'
fi
ok 'no external dependency on tobi/wrap in build, CI, or runtime files'

if grep -En 'repository_dispatch:|types: [base-image]' "$root/.github/workflows/image.yml"; then
  die 'workflow still listens for external wrap base-image dispatch'
fi
ok 'workflow has no external base-image dispatch trigger'
