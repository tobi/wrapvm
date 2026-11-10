#!/bin/bash
# Run inside a fresh, disposable wrapvm container, as the image's user, in a
# login shell: what wrapvm adds to wrap's desktop.
#   podman run --rm -v "$PWD/tests:/tests:ro" localhost/wrapvm:test bash -l /tests/container_wrapvm.sh
set -euo pipefail
ok() { printf 'ok - %s\n' "$*"; }

ffmpeg -hide_banner -version >/dev/null
ok 'ffmpeg is installed'

test "$AGENT_BROWSER_CONFIG" = /home/user/workspace/agent-browser.json
test "$(jq -c . "$AGENT_BROWSER_CONFIG")" = '{"headed":true,"autoConnect":true}'
test "$(stat -c %u "$AGENT_BROWSER_CONFIG")" = "$(id -u)"
echo '{"headed": false}' > "$AGENT_BROWSER_CONFIG"
wrap-agent-browser-config
test "$(jq -c . "$AGENT_BROWSER_CONFIG")" = '{"headed":false}'
rm "$AGENT_BROWSER_CONFIG"
sudo -n -i true   # a root login shell writes it too, owned by the workspace's user
test "$(stat -c %u "$AGENT_BROWSER_CONFIG")" = "$(id -u)"
ok 'AGENT_BROWSER_CONFIG gets its default once, never over a changed one'

if [ -d /run/smolvm ]; then kind=vm; else kind=container; fi
zsh -c 'starship prompt' | grep -q "\[$kind:$(uname -n)\]"
bash -lc 'starship prompt' | grep -q "\[$kind:$(uname -n)\]"
ok "the prompt says [$kind:$(uname -n)]"

for skill in desktop browser; do
  head -3 "$HOME/.agents/skills/$skill/SKILL.md" | grep -qx "name: $skill"
done
agent-desktop skills get desktop | jq -e '.ok' >/dev/null
agent-browser skills get core >/dev/null
ok 'the desktop and browser skills are in ~/.agents/skills, and the guides they point at answer'

page="$(mktemp -d)"
echo '<title>agent-browser page</title>' > "$page/ab.html"
agent-browser open "file://$page/ab.html" >/dev/null
curl -fsS http://127.0.0.1:9222/json/list | jq -e '[.[].title] | index("agent-browser page")' >/dev/null
ok 'agent-browser, with the default config, opens its page in the desktop Chrome'

# Google Chrome on amd64, Chromium on arm64.
chrome="$(ps -eo args | grep -E '^(/opt/google/chrome/chrome|/usr/lib/chromium/chromium)( |$)' | grep -v -- '--type=' | head -1)"
[ -n "$chrome" ]
if unshare --user --map-root-user --pid --net --fork true 2>/dev/null; then
  case "$chrome" in *--no-sandbox*) echo "Chrome runs without its sandbox: $chrome" >&2; exit 1 ;; esac
  ok 'the desktop Chrome runs with its sandbox'
else
  case "$chrome" in *--no-sandbox*) ;; *) echo "no namespaces, yet no --no-sandbox: $chrome" >&2; exit 1 ;; esac
  ok 'this runtime refuses Chrome'"'"'s namespaces (plain Docker), so it runs with --no-sandbox'
fi

test "$(xdg-mime query default x-scheme-handler/https)" = wrap-chrome.desktop
test "$(xdg-settings get default-web-browser)" = wrap-chrome.desktop
test "$BROWSER" = wrap-chrome
in_chrome() { curl -fsS http://127.0.0.1:9222/json/list | jq -e --arg t "$1" '[.[].title] | index($t)' >/dev/null; }
echo '<title>xdg-open page</title>' > "$page/xdg.html"
xdg-open "file://$page/xdg.html"
echo '<title>exo page</title>' > "$page/exo.html"
exo-open --launch WebBrowser "file://$page/exo.html"
for _ in $(seq 20); do in_chrome 'xdg-open page' && in_chrome 'exo page' && break; sleep 0.5; done
in_chrome 'xdg-open page' && in_chrome 'exo page'
ok 'Chrome is the default browser: xdg-open and XFCE open links as tabs in the shared Chrome'

# The tone goes ALSA default -> pulseaudio-alsa -> the desktop's null sink.
ffmpeg -hide_banner -loglevel error -f lavfi -i sine=d=0.2 -f alsa default
test "$(pactl get-default-sink)" = output
if grep -E 'ALSA lib|PcmOpen' "/tmp/wrap-desktop-$(id -u)/desktop.log"; then
  echo "something failed to open audio" >&2; exit 1
fi
ok "ALSA plays into the desktop's PulseAudio sink; nothing logs an ALSA error"
