# wrapvm: tobi/wrap's desktop (Containerfile.desktop at c562a7d) plus ffmpeg and
# a workspace agent-browser config. This file is the one definition of the VM:
# CI publishes it as ghcr.io/tobi/wrapvm:desktop, which the Smolfile boots.
#
# wrap desktop: base image + a headless X desktop (Xvfb + XFCE), one persistent
# Google Chrome on that desktop with CDP on localhost:9222 and every first-run/
# setup prompt suppressed system-wide, and agent-browser preconfigured to attach
# to that Chrome — so a human (in the browser viewer) and the agent share the
# same browser.
#
#   docker run -d ghcr.io/tobi/wrapvm:desktop            # desktop + chrome up
#   docker run -it ghcr.io/tobi/wrapvm:desktop           # shell, desktop autostarts
#   -e WRAP_DESKTOP_AUTOSTART=0                          # opt out of autostart
#
# The viewer, voxl on :6080, listens on all guest interfaces so the VM/container
# port publish (which targets the guest NIC, not its loopback) can reach it; the
# host side of that publish is loopback-only, and voxl still asks for a password
# and refuses other sites' pages. Chrome only binds CDP to 127.0.0.1:9222 (it
# ignores --remote-debugging-address with a window), so a socat forwarder serves
# it on all guest interfaces at :9223.
#
# Both architectures come out of this one file. On amd64 the shared browser is
# Google Chrome from its .deb; on arm64 it is Arch Linux ARM's Chromium, because
# Google publishes no linux-arm64 Chrome and the amd64 build cannot stand in for
# it (under qemu-user Chrome dies with an internal SIGTRAP before CDP is up).
# BuildKit's automatic TARGETARCH picks the branch, so `docker build .` on an
# arm64 host and `buildx build --platform linux/arm64` both do the right thing;
# on arm64 the base image is tobi/wrap's Containerfile.arm64 build (see
# README), since ghcr.io/tobi/wrap:latest is amd64-only.
ARG BASE_IMAGE=ghcr.io/tobi/wrap:latest

# ---------------------------------------------------------------------------
# voxl (github.com/tembo/voxl) is the viewer: it streams :1 to a browser as
# H.264 over one WebSocket (WebCodecs decodes it) and sends input, clipboard
# and file transfers back. It has no release binaries, so this stage builds a
# pinned commit on the same base the image runs on; only the binary leaves it,
# and the image installs the four libraries it links (x264, libyuv, opus,
# libpulse). Everything else here — Rust, esbuild, the crates — stays behind.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS voxl
# The base puts mise's shims first on PATH, and cargo there is a lazy install.
# Arch's own rust is the toolchain here.
ENV HOME=/root USER=root CARGO_HOME=/tmp/cargo PATH=/usr/bin:/bin
# --disable-sandbox: pacman 7.1 wraps its databases in a Landlock sandbox that
# BuildKit's seccomp profile refuses ("restricting filesystem access failed"),
# so every pacman call in this file passes it. Requires pacman >= 7.1, which
# both wrap bases have.
RUN pacman -Syu --disable-sandbox --noconfirm --needed rust esbuild x264 libyuv opus libpulse \
 && rm -rf /var/cache/pacman/pkg/*
# Arch's libyuv ships no pkg-config file, and voxl's build.rs asks pkg-config
# for every library it links.
RUN install -d /opt/voxl/pkgconfig \
 && cat > /opt/voxl/pkgconfig/libyuv.pc <<'EOF'
prefix=/usr
libdir=${prefix}/lib
includedir=${prefix}/include

Name: libyuv
Description: YUV conversion and scaling (Arch ships the library without this file)
Version: 0
Libs: -L${libdir} -lyuv
Cflags: -I${includedir}
EOF
# main after v0.3.2: it also rebuilds the capture when the X screen changes size
# (tembo/voxl#49) and no longer panics on a screen below 640x480 (#54).
ARG VOXL_REV=f5d6ec93dd2745a680054071eae31aec45049a49
RUN git init -q /src/voxl \
 && git -C /src/voxl fetch -q --depth 1 https://github.com/tembo/voxl "${VOXL_REV}" \
 && git -C /src/voxl checkout -q FETCH_HEAD \
 && test "$(git -C /src/voxl rev-parse HEAD)" = "${VOXL_REV}"
WORKDIR /src/voxl
# bindgen 0.71 under Arch's libclang 23 emits x264_param_t as an opaque struct,
# and encoder.rs then fails on every field it sets (E0609); 0.72.1 parses it.
# Cargo.lock changes in bindgen's own version and checksum only, so the build
# stays --locked to the rest of upstream's lockfile.
RUN sed -i 's/^bindgen = "0.71"$/bindgen = "0.72"/' Cargo.toml \
 && grep -qx 'bindgen = "0.72"' Cargo.toml \
 && cargo update --quiet -p bindgen --precise 0.72.1 \
 && PKG_CONFIG_PATH=/opt/voxl/pkgconfig cargo build --quiet --release --locked \
 && install -D -m 0755 target/release/voxl /opt/voxl/bin/voxl \
 && strip /opt/voxl/bin/voxl \
 && /opt/voxl/bin/voxl --version

FROM ${BASE_IMAGE}

# BuildKit's automatic platform arg, re-declared here because a global ARG is not
# in scope inside a stage. Picks the browser install below (Chrome / Chromium).
ARG TARGETARCH

# Build steps run as root; keep root's droppings out of the user's home. The
# runtime identity (HOME=/home/user) is restored at the end of the file.
ENV HOME=/root USER=root

# One shared X display for everything. agent-browser sees DISPLAY set and puts
# Chrome on the XFCE desktop instead of spawning a private Xvfb.
# NO_AT_BRIDGE must not be set: GTK reads it as "do not load the AT-SPI bridge",
# which hides every app from agent-desktop. GNOME_ACCESSIBILITY=1 says the
# session has accessibility on, which Chromium reads per process: with
# --no-startup-window it otherwise never initialises its AT-SPI bridge (checked:
# a window handed to it later does not change that). The bus itself is switched
# on by wrap-a11y (see the wrap-desktop section below).
ENV DISPLAY=:1 \
    WRAP_DESKTOP_GEOMETRY=1280x800x24 \
    WRAP_DESKTOP_VIEWER_PORT=6080 \
    WRAP_DESKTOP_CDP_PORT=9222 \
    WRAP_DESKTOP_CDP_PUBLIC_PORT=9223 \
    XDG_SESSION_TYPE=x11 \
    GNOME_ACCESSIBILITY=1 \
    AGENT_BROWSER_CONFIG=/home/user/workspace/agent-browser.json
# AGENT_BROWSER_CONFIG replaces agent-browser's config discovery with that one
# file, in the workspace so a person can change it per project; wrap-desktop
# and login shells write its default when it is missing
# (see wrap-agent-browser-config below).

# ---------------------------------------------------------------------------
# X + XFCE + viewer + Chrome runtime deps (Arch repos). XFCE is assembled from
# components rather than the `xfce4` group to skip power-manager, screensaver,
# pulseaudio plugin and friends — nothing here should ever lock or dim :1.
# x264, libyuv, opus and libpulse are what the voxl binary links.
# wrapvm: pulseaudio is the desktop's sound card, a null sink that voxl streams
# to the viewer; pulseaudio-alsa routes ALSA's default device into it.
# ---------------------------------------------------------------------------
RUN pacman -Syu --disable-sandbox --noconfirm --needed \
      xorg-server-xvfb xorg-xauth xorg-xdpyinfo xorg-xset xorg-xrandr xdotool \
      scrot socat x264 libyuv opus libpulse \
      dbus xfce4-session xfwm4 xfdesktop xfce4-panel xfce4-settings xfconf \
      xfce4-terminal thunar xfce4-appfinder garcon adwaita-icon-theme \
      ttf-dejavu ttf-liberation noto-fonts noto-fonts-emoji \
      alsa-lib gtk3 libcups libxss libxtst nss xdg-utils at-spi2-core procps-ng \
      libxrandr libxcomposite libxdamage libxkbcommon libdrm mesa pango cairo \
      libxshmfence vulkan-icd-loader \
      ffmpeg pulseaudio pulseaudio-alsa \
 && dbus-uuidgen --ensure=/etc/machine-id \
 && rm -rf /var/cache/pacman/pkg/*

# dconf profile. The a11y state at-spi keeps (org.a11y.Status IsEnabled, which
# it mirrors into gsettings' toolkit-accessibility) is written through dconf's
# user database. Arch ships no /etc/dconf/profile, so dconf falls back to its
# built-in default; naming it here makes the database layout explicit the way
# other distributions do. It is not a fix: this image's dconf reads and writes
# the same key without the file (checked), so do not read it as the reason
# accessibility used to stay off — that was NO_AT_BRIDGE and IsEnabled below.
RUN install -d /etc/dconf/profile \
 && printf '%s\n' 'user-db:user' > /etc/dconf/profile/user

# mise's installs are shared by every bot HOME (MISE_DATA_DIR), but its cache,
# state and locks default to $HOME. So four bots launching a tool with an update
# pending take four different locks and race over the one shared install —
# measured on this image: 3 of 4 launches died with "No executable found for
# configured tool: agent-desktop" while another process replaced it. One
# directory per uid, under a sticky parent, gives every process of a uid the
# same lock domain wherever HOME points, and keeps root in its own: the base
# image's per-uid defaults exist so a sudo shell cannot poison the user's
# install state, and this keeps that true.
#
# The pin is a snippet two entry points share: /etc/profile.d/wrap.sh (login
# shells, and every zsh through /etc/zsh/zshenv) and wrap-desktop, which sources
# it before it starts XFCE, a terminal or Chrome — those are not login shells
# either. This runs before the eager `mise install` below, so the image's own
# install populates the same cache and state a plain first call uses; an empty
# state directory would make that call re-resolve and, offline, stall.
RUN install -d -m 1777 /opt/mise/cache /opt/mise/state \
 && cat > /opt/wrap/bin/wrap-mise-env <<'EOF'
# mise: one cache and state directory per uid, independent of HOME. Sourced by
# /etc/profile.d/wrap.sh and by wrap-desktop, so a bot's commands and the
# desktop's own processes share the uid's install lock instead of racing.
#  - [ -O ]: a directory that is not ours is left alone. Root and the user never
#    write into each other's state, and a root-owned leftover is not adopted.
#  - the snippet never fails a shell: every step that can fail ends in `continue`.
for kind in cache state; do
  case $kind in
    cache) var=MISE_CACHE_DIR ;;
    state) var=MISE_STATE_DIR ;;
  esac
  dir="/opt/mise/$kind/$(id -u)"
  [ -d "/opt/mise/$kind" ] || continue
  mkdir -p "$dir" 2>/dev/null || continue
  [ -O "$dir" ] || continue
  export "$var=$dir"
done
EOF
RUN chmod 0644 /opt/wrap/bin/wrap-mise-env \
 && printf '%s\n' '[ -r /opt/wrap/bin/wrap-mise-env ] && . /opt/wrap/bin/wrap-mise-env' \
      >> /etc/profile.d/wrap.sh

# `sudo -E` would carry the user's MISE_CACHE_DIR/MISE_STATE_DIR into a root
# shell, and root's mise would then leave root-owned locks and a root-owned
# trust state in the user's directory: the user's next install fails on files it
# may not write. sudo drops both for every command here. An explicit
# `sudo --preserve-env=MISE_STATE_DIR …` still hands one over — that is sudo's
# own escape hatch, and it cannot be closed from sudoers without turning
# preservation off everywhere.
RUN cat > /etc/sudoers.d/20-wrap-mise <<'EOF'
Defaults env_delete += "MISE_CACHE_DIR MISE_STATE_DIR"
EOF
RUN chmod 0440 /etc/sudoers.d/20-wrap-mise \
 && visudo -cf /etc/sudoers.d/20-wrap-mise

# Both agent CLIs are in the image and need no download on first use:
#
#  - agent-browser through mise's native registry backend (no npm, no Node in
#    its call path, no custom launcher).
#  - agent-desktop through mise's npm backend. The npm package ships the native
#    binaries; its postinstall is what copies the platform binary over the Node
#    launcher and puts agent-desktop-linux-clipboard-owner beside it. npm runs
#    no package scripts by default, and mise's embedded aube follows it, so the
#    declaration approves exactly that one package (allow_builds) — nothing
#    else runs, and npm's --ignore-scripts is not turned off globally.
#    Running the postinstall needs node, which mise installs as a dependency.
#
# Updates stay with mise: the base config sets tool_update.global_auto, so an
# installed tool is refreshed before it launches once mise's check interval has
# passed. `mise install` here names its tools on purpose: a bare `mise install`
# would also pull every lazy runtime in the base config, and node is named
# because mise does not fetch a lazy node for an npm tool by itself (it fails
# with "failed to resolve configured install dependency 'node@latest'").
COPY --chown=${WRAP_UID}:${WRAP_GID} resources/mise-desktop.toml /opt/mise/config/conf.d/desktop.toml
RUN sudo -u "${WRAP_USER_NAME}" -H sh -lc 'mise install node agent-browser npm:agent-desktop'

# The viewer, from the voxl stage at the top. Its web client is compiled into
# the binary, so it serves offline. LD_BIND_NOW makes the loader resolve every
# symbol voxl uses before --version runs: a runtime library that drifted from
# the one it was built against fails the build here, not a desktop start.
COPY --from=voxl /opt/voxl/bin/voxl /usr/local/bin/voxl
RUN LD_BIND_NOW=1 voxl --version

# ---------------------------------------------------------------------------
# The shared browser, one install per architecture, both ending at the same
# path: /usr/lib/wrap/browser, which every launcher below execs.
#
#  amd64 — Google Chrome stable, straight from Google's .deb (the AUR package
#          does the same thing). No dpkg needed: bsdtar unpacks data.tar.* onto
#          /. Cron/apt repo hooks from the package are dropped.
#  arm64 — Arch Linux ARM's Chromium. Google ships no linux-arm64 Chrome, and
#          the amd64 build dies under qemu-user emulation (internal SIGTRAP)
#          before CDP is up, so emulating it is not an option. Chromium is the
#          same engine: CDP, policies, initial_preferences and agent-browser's
#          autoConnect work the same way. It has no Widevine and no Google
#          auto-update, and its icon is aliased to google-chrome so the dock,
#          the .desktop entry and XFCE's helper keep resolving.
# ---------------------------------------------------------------------------
RUN set -eu; : "${TARGETARCH:=amd64}"; \
    install -d /usr/lib/wrap; \
    if [ "$TARGETARCH" = arm64 ]; then \
      pacman -S --disable-sandbox --noconfirm --needed chromium; \
      rm -rf /var/cache/pacman/pkg/*; \
      chmod 4755 /usr/lib/chromium/chrome-sandbox; \
      for s in 16 24 32 48 64 128 256; do \
        src="/usr/share/icons/hicolor/${s}x${s}/apps/chromium.png"; \
        if [ ! -f "$src" ]; then \
          src="/usr/share/icons/hicolor/${s}x${s}/apps/chromium-browser.png"; \
        fi; \
        if [ -f "$src" ]; then \
          install -D -m 0644 "$src" \
            "/usr/share/icons/hicolor/${s}x${s}/apps/google-chrome.png"; \
        fi; \
      done; \
      gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true; \
      ln -sfn /usr/bin/chromium /usr/lib/wrap/browser; \
    else \
      curl -fsSL -o /tmp/chrome.deb \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; \
      bsdtar -xOf /tmp/chrome.deb 'data.tar.*' | bsdtar -x -C /; \
      rm -f /tmp/chrome.deb /etc/cron.daily/google-chrome; \
      rm -rf /opt/google/chrome/cron; \
      ln -sf /opt/google/chrome/google-chrome /usr/bin/google-chrome-stable; \
      ln -sf /opt/google/chrome/google-chrome /usr/bin/google-chrome; \
      chmod 4755 /opt/google/chrome/chrome-sandbox; \
      for s in 16 24 32 48 64 128 256; do \
        install -D -m 0644 "/opt/google/chrome/product_logo_$s.png" \
          "/usr/share/icons/hicolor/${s}x${s}/apps/google-chrome.png"; \
      done; \
      gtk-update-icon-cache -f -t /usr/share/icons/hicolor; \
      ln -sfn /opt/google/chrome/google-chrome /usr/lib/wrap/browser; \
    fi; \
    /usr/lib/wrap/browser --version
# (The .deb's postinst, which we skip, is what normally installs those icons;
#  the hicolor cache must be rebuilt or GTK trusts the stale one and shows "?".)

# ---------------------------------------------------------------------------
# Speedrun Chrome's setup. Two layers, both system-wide:
#
#  1. Managed policies (/etc/opt/chrome/policies/managed): authoritative, apply
#     to every profile including the fresh user-data-dirs agent-browser makes.
#     Kill sign-in, sync, default-browser nag, privacy-sandbox dialog, promos,
#     password/autofill bubbles, notifications/geolocation prompts, metrics,
#     field-trial surprises. Remote debugging stays allowed (agent-browser/CDP).
#  2. initial_preferences (formerly master_preferences): consumed once on
#     profile creation — no welcome/first-run UI, no import wizard, new-tab
#     page on startup, bookmarks bar hidden.
# ---------------------------------------------------------------------------
# arm64: Chromium reads its policy and initial_preferences directory from
# /etc/chromium (Chrome's branded path is /etc/opt/chrome). One directory, two
# names: the symlink keeps a single set of files working for both browsers.
RUN install -d /etc/opt/chrome/policies/managed /etc/opt/chrome/policies/recommended \
 && { [ "$TARGETARCH" != arm64 ] || ln -sfn /etc/opt/chrome /etc/chromium; } \
 && cat > /etc/opt/chrome/policies/managed/00-wrap.json <<'EOF'
{
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "BrowserAddPersonEnabled": false,
  "BrowserGuestModeEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "PromotionalTabsEnabled": false,
  "PrivacySandboxPromptEnabled": false,
  "PrivacySandboxAdMeasurementEnabled": false,
  "PrivacySandboxAdTopicsEnabled": false,
  "PrivacySandboxSiteEnabledAdsEnabled": false,
  "MetricsReportingEnabled": false,
  "UrlKeyedAnonymizedDataCollectionEnabled": false,
  "CloudReportingEnabled": false,
  "ChromeVariations": 2,
  "PasswordManagerEnabled": false,
  "PasswordLeakDetectionEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "PaymentMethodQueryEnabled": false,
  "TranslateEnabled": false,
  "SpellCheckServiceEnabled": false,
  "SearchSuggestEnabled": false,
  "AlternateErrorPagesEnabled": false,
  "BackgroundModeEnabled": false,
  "HighEfficiencyModeEnabled": false,
  "BatterySaverModeAvailability": 0,
  "RestoreOnStartup": 5,
  "HomepageIsNewTabPage": true,
  "ShowHomeButton": false,
  "BookmarkBarEnabled": false,
  "NTPCardsVisible": false,
  "NTPMiddleSlotAnnouncementVisible": false,
  "ShoppingListEnabled": false,
  "SideSearchEnabled": false,
  "DefaultNotificationsSetting": 2,
  "DefaultGeolocationSetting": 2,
  "DefaultSensorsSetting": 2,
  "DefaultWebBluetoothGuardSetting": 2,
  "DefaultWebUsbGuardSetting": 2,
  "AudioCaptureAllowed": false,
  "VideoCaptureAllowed": false,
  "DeveloperToolsAvailability": 1,
  "RemoteDebuggingAllowed": true
}
EOF
RUN cat > /etc/opt/chrome/initial_preferences <<'EOF'
{
  "homepage_is_newtabpage": true,
  "browser": {
    "show_home_button": false,
    "check_default_browser": false,
    "has_seen_welcome_page": true
  },
  "session": { "restore_on_startup": 5 },
  "bookmark_bar": { "show_on_all_tabs": false },
  "first_run_tabs": [],
  "sync_promo": { "show_on_first_run_allowed": false, "user_skipped": true },
  "distribution": {
    "skip_first_run_ui": true,
    "suppress_first_run_bubble": true,
    "suppress_first_run_default_browser_prompt": true,
    "make_chrome_default": false,
    "make_chrome_default_for_user": false,
    "import_bookmarks": false,
    "import_history": false,
    "import_home_page": false,
    "import_search_engine": false,
    "do_not_create_desktop_shortcut": true,
    "do_not_create_quick_launch_shortcut": true,
    "do_not_create_taskbar_shortcut": true,
    "do_not_launch_chrome": true,
    "do_not_register_for_update_launch": true,
    "verbose_logging": false
  }
}
EOF
# Chrome looks for initial_preferences beside its binary; Chromium looks in
# /etc/chromium, which the symlink above already points at these files.
RUN [ "$TARGETARCH" = arm64 ] \
 || install -D -m 0644 /etc/opt/chrome/initial_preferences /opt/google/chrome/initial_preferences

# Launcher that every consumer goes through (PATH puts /usr/local/bin first,
# so it shadows the deb's /usr/bin symlink for the .desktop entry too).
#  - container-safe flags: no /dev/shm reliance, no first-run, no default check
#  - root gets --no-sandbox (Chrome refuses to start as uid 0 otherwise), and
#    so does a runtime that refuses Chrome's namespaces (see below).
#  - user flags, one per line, from ~/.config/chrome-flags.conf (Arch's
#    google-chrome convention), else /etc/wrap/chrome-flags.conf. They apply to
#    every launch: the shared desktop Chrome, the dock, and any Chrome that
#    agent-browser starts itself.
RUN cat > /usr/local/bin/google-chrome-stable <<'EOF'
#!/bin/sh
n=$#
conf="${XDG_CONFIG_HOME:-$HOME/.config}/chrome-flags.conf"
[ -r "$conf" ] || conf=/etc/wrap/chrome-flags.conf
if [ -r "$conf" ]; then
  while read -r flag || [ -n "$flag" ]; do
    case "$flag" in ''|'#'*) ;; *) set -- "$@" "$flag" ;; esac
  done < "$conf"
fi
# Rotate the caller's arguments (URLs) back behind the configured flags.
while [ "$n" -gt 0 ]; do a=$1; shift; set -- "$@" "$a"; n=$((n - 1)); done
# --password-store=basic: never trigger a keyring unlock dialog.
# --force-renderer-accessibility: publish the web contents on the AT-SPI tree.
# Chromium leaves renderer accessibility off until an assistive technology is
# detected, which on this image nothing does; agent-desktop reads desktop apps
# through that tree (wrap-a11y switches the bus on).
# wrapvm: --no-sandbox only where Chrome cannot have a sandbox: as root, or
# where the user, PID and network namespaces it needs are refused (Docker's
# default seccomp profile; Chrome then dies with "failed to move to new
# namespaces"). smolvm, podman and docker --security-opt seccomp=unconfined
# allow them, so Chrome keeps its sandbox there. It goes after the fixed flags:
# what looks for the browser process matches on --disable-dev-shm-usage first.
if [ "$(id -u)" = 0 ] || ! unshare --user --map-root-user --pid --net --fork true 2>/dev/null; then
  set -- --no-sandbox "$@"
fi
set -- --disable-dev-shm-usage --no-first-run --no-default-browser-check \
       --password-store=basic --force-renderer-accessibility "$@"
exec /usr/lib/wrap/browser "$@"
EOF
# wrapvm: no --no-sandbox here; Chrome keeps its sandbox.
# Chrome honors only the last --enable-features: keep both WebMCP features in
# any replacement line, or agent-browser's `webmcp` commands find no tools.
# The page API is the WebMCP feature. Chrome 157 removed WebMCPTesting, which
# 156 also took, so a line that names only that one leaves pages without it.
RUN cat > /etc/wrap/chrome-flags.conf <<'EOF'
# Extra Google Chrome flags, one per line. Copy to ~/.config/chrome-flags.conf
# to change them; restart Chrome with `wrap-desktop stop && wrap-desktop start`.
# WebMCP: pages register tools on document.modelContext; agent-browser lists
# and calls them with `agent-browser webmcp list|invoke`.
--enable-features=WebMCP,DevToolsWebMCPSupport
EOF
RUN chmod 0755 /usr/local/bin/google-chrome-stable \
 && ln -sf google-chrome-stable /usr/local/bin/google-chrome \
 && ln -sf google-chrome-stable /usr/local/bin/chrome

# wrap-chrome: open in the *shared* desktop Chrome (the CDP instance) rather
# than a second profile. Chrome hands the URL to the running instance when the
# profile dir matches. Used by wrap-desktop and by the dock launcher.
RUN cat > /usr/local/bin/wrap-chrome <<'EOF'
#!/bin/sh
: "${WRAP_DESKTOP_CHROME_PROFILE:=$HOME/.config/wrap-chrome}"
: "${WRAP_DESKTOP_CDP_PORT:=9222}"
exec google-chrome-stable --user-data-dir="$WRAP_DESKTOP_CHROME_PROFILE" \
  --remote-debugging-port="$WRAP_DESKTOP_CDP_PORT" --remote-debugging-address=127.0.0.1 "$@"
EOF
RUN chmod 0755 /usr/local/bin/wrap-chrome \
 && cat > /usr/share/applications/wrap-chrome.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Comment=Shared desktop browser (CDP on localhost:9222)
Exec=wrap-chrome %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;
StartupWMClass=Google-chrome
EOF

# agent-browser defaults: user-level config (~/.agent-browser/config.json) so
# a project-level ./agent-browser.json can still layer on top. Seeded into
# /etc/skel for future users and copied to the two accounts that exist.
#  - cdp: attach to the persistent desktop Chrome that wrap-desktop runs with
#    --remote-debugging-port on localhost. Agent and human share one browser.
#  - executablePath/headed: only used if something overrides cdp (e.g. a
#    project config wanting an isolated browser) — still real Chrome, on :1.
#  - idleTimeout 0: the daemon never tears the visible browser down.
RUN install -d /etc/skel/.agent-browser /etc/wrap \
 && cat > /etc/skel/.agent-browser/config.json <<'EOF'
{
  "$schema": "https://agent-browser.dev/schema.json",
  "cdp": "9222",
  "executablePath": "/usr/local/bin/google-chrome-stable",
  "headed": true,
  "idleTimeout": "0",
  "screenshotDir": "/tmp/agent-browser-screenshots"
}
EOF
RUN for home in /root /home/user; do \
      install -d "$home/.agent-browser"; \
      cp /etc/skel/.agent-browser/config.json "$home/.agent-browser/config.json"; \
    done \
 && chown -R "${WRAP_UID}:${WRAP_GID}" /home/user/.agent-browser

# wrapvm: agent-browser's config is AGENT_BROWSER_CONFIG, which replaces the
# ~/.agent-browser/config.json above. It is written once, when missing, from
# /etc/wrap/agent-browser.json: headed, and attached to the desktop's running
# Chrome by discovery.
RUN cat > /etc/wrap/agent-browser.json <<'EOF'
{
  "headed": true,
  "autoConnect": true
}
EOF
RUN cat > /opt/wrap/bin/wrap-agent-browser-config <<'EOF'
#!/bin/sh
# Write the default agent-browser config at $AGENT_BROWSER_CONFIG when nothing
# is there yet and its directory exists. Never overwrites.
file="${AGENT_BROWSER_CONFIG:-}"
[ -n "$file" ] && [ ! -e "$file" ] || exit 0
dir="$(dirname "$file")"
[ -d "$dir" ] && [ -w "$dir" ] || exit 0
(set -C; cat /etc/wrap/agent-browser.json > "$file") 2>/dev/null || exit 0
# Written by root (a sudo -i shell): it still belongs to the workspace's owner.
[ "$(id -u)" != 0 ] || chown "$(stat -c %u:%g "$dir")" "$file"
EOF
# The image's own workspace gets it now, for a container without a workspace
# mount: agent-browser refuses to run while AGENT_BROWSER_CONFIG names a
# missing file. A mounted workspace gets it from the desktop's first start.
RUN chmod 0755 /opt/wrap/bin/wrap-agent-browser-config \
 && install -o "${WRAP_UID}" -g "${WRAP_GID}" -m 0644 /etc/wrap/agent-browser.json \
      /home/user/workspace/agent-browser.json

# wrapvm: agent-browser's guides (`agent-browser skills get core`). The native
# build mise installs has no skill-data beside it (only the npm package ships
# one), so it is fetched from the release the image installed. mise updates the
# binary later on its own; the guides of this version stay until a rebuild.
ENV AGENT_BROWSER_SKILLS_DIR=/opt/agent-browser/skill-data
RUN v="$(sudo -u "${WRAP_USER_NAME}" -H sh -lc 'agent-browser --version' | awk '{print $2}')" \
 && install -d /opt/agent-browser \
 && curl -fsSL "https://github.com/vercel-labs/agent-browser/archive/refs/tags/v$v.tar.gz" \
      | bsdtar -x -C /opt/agent-browser --strip-components 1 "agent-browser-$v/skill-data" \
 && chmod -R a+rX /opt/agent-browser \
 && sudo -u "${WRAP_USER_NAME}" -H env AGENT_BROWSER_SKILLS_DIR="$AGENT_BROWSER_SKILLS_DIR" sh -lc 'agent-browser skills get core' | head -3 | grep -qx 'name: core'

# wrapvm: the desktop's sound. No hardware: one PulseAudio server per desktop,
# started by wrap-desktop as the desktop's uid, whose only sink is a null one
# named `output`. Chrome, ffmpeg and ALSA apps (through pulseaudio-alsa) play
# into it; voxl streams its monitor, output.monitor, to the viewer, and
# `ffmpeg -f pulse -i output.monitor` records it. The socket is
# $XDG_RUNTIME_DIR/pulse/native, in a 0700 directory: any process of that uid
# may play, whatever its HOME (so no cookie).
RUN cat > /etc/wrap/pulse.pa <<'EOF'
load-module module-native-protocol-unix auth-anonymous=1
load-module module-null-sink sink_name=output sink_properties=device.description=Desktop
set-default-sink output
set-default-source output.monitor
EOF
# Clients find that server whatever their environment (a shell without
# XDG_RUNTIME_DIR, root), and never spawn a second, sinkless one of their own.
RUN install -d /etc/pulse/client.conf.d \
 && printf '%s\n' 'autospawn = no' \
      "default-server = unix:/tmp/wrap-desktop-${WRAP_UID}/runtime/pulse/native" \
      > /etc/pulse/client.conf.d/50-wrapvm.conf

# wrapvm: the shared desktop Chrome is the default browser, for everything
# that opens a link: xdg-open, gio, GTK apps (mimeapps.list), XFCE's own
# launchers (exo's WebBrowser helper) and CLI tools that read $BROWSER. All
# of them go through wrap-chrome, so a link opens as a tab in the Chrome that
# agent-browser and the person share, never in a second profile.
ENV BROWSER=wrap-chrome
RUN cat > /etc/xdg/mimeapps.list <<'EOF'
[Default Applications]
x-scheme-handler/http=wrap-chrome.desktop
x-scheme-handler/https=wrap-chrome.desktop
x-scheme-handler/about=wrap-chrome.desktop
x-scheme-handler/unknown=wrap-chrome.desktop
text/html=wrap-chrome.desktop
application/xhtml+xml=wrap-chrome.desktop
application/pdf=wrap-chrome.desktop
EOF
RUN install -d /etc/xdg/xfce4 \
 && printf '%s\n' 'WebBrowser=wrap-chrome' > /etc/xdg/xfce4/helpers.rc \
 && cat > /usr/share/xfce4/helpers/wrap-chrome.desktop <<'EOF'
[Desktop Entry]
NoDisplay=true
Version=1.0
Type=X-XFCE-Helper
X-XFCE-Category=WebBrowser
X-XFCE-Commands=wrap-chrome
X-XFCE-CommandsWithParameter=wrap-chrome "%s"
Icon=google-chrome
Name=Google Chrome (shared desktop)
EOF

# wrapvm: the prompt says [vm:<machine>] under smolvm, [container:<host>] in a
# container. smolvm's guest init leaves /run/smolvm; zshenv and login shells
# both source wrap.sh, so the choice is made there.
RUN sed 's/container:\$hostname/vm:\$hostname/' /etc/wrap/starship.toml > /etc/wrap/starship-vm.toml \
 && grep -q 'vm:\$hostname' /etc/wrap/starship-vm.toml \
 && printf '%s\n' '[ -d /run/smolvm ] && export STARSHIP_CONFIG=/etc/wrap/starship-vm.toml' >> /etc/profile.d/wrap.sh

# wrapvm: the desktop and browser skills, global for agents (pi, Claude Code,
# Codex read ~/.agents/skills). Seeded into /etc/skel and both existing homes;
# /etc/wrap/skills keeps a copy for an agent whose HOME is somewhere else.
COPY skills/ /etc/wrap/skills/
RUN for home in /etc/skel /root /home/user; do \
      install -d "$home/.agents/skills"; \
      cp -a /etc/wrap/skills/. "$home/.agents/skills/"; \
    done \
 && chmod -R a+rX /etc/wrap/skills \
 && chown -R "${WRAP_UID}:${WRAP_GID}" /home/user/.agents

# XFCE look: no top bar, one centered bottom dock with three launchers
# (Chrome / Thunar / Terminal) on a transparent panel, solid navy backdrop,
# no desktop icons or right-click menu, nothing that can lock or prompt.
# Seeded into /etc/skel and both existing homes so the first start is final.
RUN install -d /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml \
      /etc/skel/.config/xfce4/panel/launcher-1 \
      /etc/skel/.config/xfce4/panel/launcher-2 \
      /etc/skel/.config/xfce4/panel/launcher-3 \
 && cp /usr/share/applications/wrap-chrome.desktop     /etc/skel/.config/xfce4/panel/launcher-1/ \
 && cp /usr/share/applications/thunar.desktop          /etc/skel/.config/xfce4/panel/launcher-2/ \
 && cp /usr/share/applications/xfce4-terminal.desktop  /etc/skel/.config/xfce4/panel/launcher-3/ \
 && cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="dark-mode" type="bool" value="true"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=10;x=0;y=0"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="length" type="uint" value="1"/>
      <property name="size" type="uint" value="64"/>
      <property name="icon-size" type="uint" value="48"/>
      <property name="autohide-behavior" type="uint" value="0"/>
      <property name="background-style" type="uint" value="1"/>
      <property name="background-rgba" type="array">
        <value type="double" value="0"/>
        <value type="double" value="0"/>
        <value type="double" value="0"/>
        <value type="double" value="0"/>
      </property>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="launcher">
      <property name="items" type="array"><value type="string" value="wrap-chrome.desktop"/></property>
    </property>
    <property name="plugin-2" type="string" value="launcher">
      <property name="items" type="array"><value type="string" value="thunar.desktop"/></property>
    </property>
    <property name="plugin-3" type="string" value="launcher">
      <property name="items" type="array"><value type="string" value="xfce4-terminal.desktop"/></property>
    </property>
  </property>
</channel>
EOF
RUN cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="LockCommand" type="string" value=""/>
    <property name="SaveOnExit" type="bool" value="false"/>
    <property name="PromptOnLogout" type="bool" value="false"/>
  </property>
  <property name="shutdown" type="empty">
    <property name="LockScreen" type="bool" value="false"/>
  </property>
</channel>
EOF
# Xvfb's RANDR output is named "screen", hence monitorscreen.
RUN cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorscreen" type="empty">
        <property name="workspace0" type="empty">
          <property name="image-style" type="int" value="0"/>
          <property name="color-style" type="int" value="0"/>
          <property name="rgba1" type="array">
            <value type="double" value="0.11"/>
            <value type="double" value="0.14"/>
            <value type="double" value="0.21"/>
            <value type="double" value="1"/>
          </property>
        </property>
      </property>
    </property>
  </property>
  <property name="desktop-icons" type="empty">
    <property name="style" type="int" value="0"/>
  </property>
  <property name="desktop-menu" type="empty">
    <property name="show" type="bool" value="false"/>
  </property>
</channel>
EOF
# Compositing off. With xfwm4's compositor running, the X root window holds only
# the compositor's own stage, not the app windows, so a whole-screen capture
# cannot see what is on screen; agent-desktop refuses it outright
# (`screenshot --screen 0` -> PLATFORM_NOT_SUPPORTED, reason compositing).
# Without a compositor the root window holds the windows themselves and the
# capture is truthful. Nothing in this desktop needs the compositor: no
# transparency, no shadows, no window previews.
RUN cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF
RUN for home in /root /home/user; do \
      install -d "$home/.config"; \
      cp -a /etc/skel/.config/xfce4 "$home/.config/"; \
    done \
 && chown -R "${WRAP_UID}:${WRAP_GID}" /home/user/.config

# ---------------------------------------------------------------------------
# wrap-a11y: switch the AT-SPI accessibility bus on for this session.
#
# agent-desktop reads desktop apps through AT-SPI, and a toolkit publishes its
# tree only while org.a11y.Status.IsEnabled is true on the session bus. at-spi's
# bus launcher keeps that flag in memory (bus/at-spi-bus-launcher.c: it is
# zero-initialised, written to gsettings' toolkit-accessibility in
# handle_a11y_enabled_change and cleared when no app holds an event listener),
# so it is an input that must be set after every launcher start — `gsettings set
# org.gnome.desktop.interface toolkit-accessibility true` alone does nothing.
#
#   wrap-a11y enable [--quiet]  switch it on if it is off; safe to repeat
#   wrap-a11y status            print the state, exit 0 when it is on
#   wrap-a11y watch             keep it on: re-enable when a launcher appears
#                               or when the bus reports IsEnabled false itself
#
# Every wait is bounded (a condition with a deadline, never a forever poll).
# ---------------------------------------------------------------------------
RUN cat > /opt/wrap/bin/wrap-a11y <<'EOF'
#!/bin/sh
set -eu
: "${XDG_RUNTIME_DIR:=/tmp/wrap-desktop-$(id -u)/runtime}"
: "${DBUS_SESSION_BUS_ADDRESS:=unix:path=$XDG_RUNTIME_DIR/bus}"
export XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
quiet=0
say() { [ "$quiet" = 1 ] || printf '%s\n' "$*" >&2; }

bus_up() {
  dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
    /org/freedesktop/DBus org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1
}

# The property, not gsettings: the launcher writes gsettings from it.
is_enabled() {
  gdbus call --session -d org.a11y.Bus -o /org/a11y/bus \
    -m org.freedesktop.DBus.Properties.Get org.a11y.Status IsEnabled 2>/dev/null \
    | grep -q 'true'
}

# D-Bus activates the launcher and its private bus on first use, so this also
# brings the a11y bus itself up when nothing has asked for it yet.
launcher_up() {
  gdbus call --session -d org.a11y.Bus -o /org/a11y/bus \
    -m org.a11y.Bus.GetAddress >/dev/null 2>&1
}

wait_for() { # tries command...
  tries=$1; shift
  i=0
  until "$@"; do
    i=$((i + 1)); [ "$i" -lt "$tries" ] || return 1
    sleep 0.1
  done
}

# The desktop belongs to the uid that started its Xvfb. Only that uid may switch
# the bus on: the launcher publishes its address on the shared root window, so a
# second uid (a `sudo -i` login shell runs `wrap-desktop start` too) would start
# a launcher of its own and point every app — the user's included — at a bus
# under /tmp/wrap-desktop-0 that they cannot connect to.
owns_desktop() {
  pidfile="/tmp/wrap-desktop-$(id -u)/xvfb.pid"
  [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null
}

enable() {
  if ! owns_desktop; then
    say "wrap-a11y: the desktop is not this uid's; leaving accessibility to its owner"
    return 0
  fi
  if ! wait_for 100 bus_up; then
    say "wrap-a11y: no session bus at $DBUS_SESSION_BUS_ADDRESS"
    return 1
  fi
  if ! launcher_up; then
    say "wrap-a11y: org.a11y.Bus did not answer"
    return 1
  fi
  # Already on: nothing to write (a repeat call costs two D-Bus calls).
  if is_enabled; then
    say "accessibility already on"
    return 0
  fi
  if ! gdbus call --session -d org.a11y.Bus -o /org/a11y/bus \
      -m org.freedesktop.DBus.Properties.Set \
      org.a11y.Status IsEnabled '<true>' >/dev/null; then
    say "wrap-a11y: setting org.a11y.Status IsEnabled failed"
    return 1
  fi
  if ! wait_for 20 is_enabled; then
    say "wrap-a11y: org.a11y.Status IsEnabled did not stay true"
    return 1
  fi
  say "accessibility on"
}

# Event-driven recovery, on the bus's own signals: gdbus prints one line per
# event, so nothing has to be parsed. Two of them matter:
#
#   "The name org.a11y.Bus is owned by :1.7" / "does not have an owner"
#       — a launcher appeared (a fresh one starts switched off) or went away.
#   "/org/a11y/bus: …PropertiesChanged ('org.a11y.Status', {'IsEnabled': <false>}, @as [])"
#       — the launcher switched itself off, which it does when the last client
#       that held an AT-SPI event listener disconnects (at-spi-bus-launcher.c,
#       event_listener_vanished_callback). No name change is involved, so this
#       is the only event that says accessibility just went off.
#
# Only a false value is acted on; our own write reports <true>, so this cannot
# loop. When the session bus goes away the monitor ends; `wrap-desktop run`
# starts this piece again and `start` switches accessibility on there too.
watch() {
  enable || true
  owns_desktop || return 0
  gdbus monitor --session --dest org.a11y.Bus 2>/dev/null |
  while read -r line; do
    case "$line" in
      *'name org.a11y.Bus'*) enable || true ;;
      *PropertiesChanged*"'IsEnabled': <false>"*) enable || true ;;
    esac
  done
}

cmd="${1:-enable}"; [ $# -gt 0 ] && shift
for a in "$@"; do [ "$a" = "--quiet" ] && quiet=1; done
case "$cmd" in
  enable) enable ;;
  watch)  watch ;;
  status)
    if is_enabled; then say "accessibility on"; else say "accessibility off"; exit 1; fi ;;
  *) echo "usage: wrap-a11y enable [--quiet] | status | watch | (watch: re-enables on a new launcher or an IsEnabled false report)" >&2; exit 2 ;;
esac
EOF
RUN chmod 0755 /opt/wrap/bin/wrap-a11y

# ---------------------------------------------------------------------------
# wrap-desktop: idempotent supervisor for Xvfb :1 + XFCE + Chrome (CDP) + the
# voxl viewer. Runs as whoever calls it (normally `user`). Xvfb is started
# with -ac so any uid in the VM (sudo, root plumbing) can also draw on :1.
# Each `start` re-spawns whichever piece has died, so a crashed Chrome comes
# back on the next login shell; `run` also does that every
# WRAP_DESKTOP_SUPERVISE_SECONDS (default 30, 0 disables) and stops cleanly on
# SIGTERM, so a failed piece never takes the container down with it.
#
#   wrap-desktop start [--quiet]   bring the desktop up if :1 is not live
#   wrap-desktop status            exit 0 when :1 answers
#   wrap-desktop stop              tear down what this uid started
#   wrap-desktop run               start, supervise, block (container CMD)
#   wrap-desktop url [ADDRESS]     print the viewer's sign-in link
#   wrap-desktop password          print the viewer's password
#
# Accessibility: `start` switches the AT-SPI bus on (wrap-a11y) before XFCE and
# Chrome start, and supervises `wrap-a11y watch`, so agent-desktop can read the
# desktop's apps and a bus launcher that dies mid-session comes back on its own.
# ---------------------------------------------------------------------------
RUN cat > /opt/wrap/bin/wrap-desktop <<'EOF'
#!/bin/sh
set -eu

: "${DISPLAY:=:1}"
: "${WRAP_DESKTOP_GEOMETRY:=1280x800x24}"
: "${WRAP_DESKTOP_VIEWER_PORT=6080}"
: "${WRAP_DESKTOP_VOXL_ARGS:=}"
: "${WRAP_DESKTOP_CDP_PORT:=9222}"
: "${WRAP_DESKTOP_CDP_PUBLIC_PORT=9223}"
: "${WRAP_DESKTOP_CHROME_PROFILE:=$HOME/.config/wrap-chrome}"
: "${WRAP_DESKTOP_SUPERVISE_SECONDS:=30}"
export DISPLAY

dpy_num="${DISPLAY#:}"; dpy_num="${dpy_num%%.*}"
run_dir="/tmp/wrap-desktop-$(id -u)"
log="$run_dir/desktop.log"
# Private session bus + runtime dir. dbus-launch's X11 autolaunch is compiled
# out on Arch, so without this xfce4-session starts but never spawns xfwm4,
# the panel or xfdesktop (xfconf needs the bus). Same values are exported to
# login shells by /etc/profile.d/wrap-desktop.sh so later GUI launches join it.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$run_dir/runtime}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
# The desktop's children (XFCE, terminals, Chrome) are not login shells, so they
# get the uid's mise cache/state here rather than from /etc/profile.d.
[ -r /opt/wrap/bin/wrap-mise-env ] && . /opt/wrap/bin/wrap-mise-env
quiet=0

say() { [ "$quiet" = 1 ] || printf '%s\n' "$*" >&2; }

display_up() { xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; }
bus_up() { dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
  /org/freedesktop/DBus org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; }
# This uid's desktop is the one whose Xvfb it started (same rule as wrap-a11y).
owns_desktop() { [ -f "$run_dir/xvfb.pid" ] && kill -0 "$(cat "$run_dir/xvfb.pid" 2>/dev/null)" 2>/dev/null; }

# Chrome trusts NSS (~/.pki/nssdb), not the system CA store. Import every local
# CA anchor so TLS-intercepting sandboxes (microsandbox secret injection puts
# its CA at /.msb/tls/ca.pem and in the Arch anchors dir) work in the browser
# exactly like they already do for curl/mise.
trust_local_cas() {
  command -v certutil >/dev/null 2>&1 || return 0
  db="$HOME/.pki/nssdb"
  install -d -m 0700 "$db"
  [ -f "$db/cert9.db" ] || certutil -d "sql:$db" -N --empty-password >>"$log" 2>&1
  for ca in /.msb/tls/ca.pem /etc/ca-certificates/trust-source/anchors/*; do
    [ -r "$ca" ] || continue
    nick="local-ca-$(basename "$ca" | sed 's/\.[^.]*$//')"
    certutil -d "sql:$db" -L -n "$nick" >/dev/null 2>&1 && continue
    certutil -d "sql:$db" -A -t "C,," -n "$nick" -i "$ca" >>"$log" 2>&1 \
      && say "chrome trusts $ca"
  done
}
pulse_up() { pactl info >/dev/null 2>&1; }
cdp_up() { curl -fsS -m 1 "http://127.0.0.1:$WRAP_DESKTOP_CDP_PORT/json/version" >/dev/null 2>&1; }
viewer_on() { case "$WRAP_DESKTOP_VIEWER_PORT" in ''|0) return 1 ;; esac; }
viewer_up() { curl -fsS -m 1 -o /dev/null "http://127.0.0.1:$WRAP_DESKTOP_VIEWER_PORT/healthz" 2>/dev/null; }

# The viewer's password: WRAP_DESKTOP_PASSWORD when set, else one made up (128
# random bits) on the owner's first start and kept in
# /var/lib/wrap-desktop/<uid>/password, so a saved link keeps working across
# restarts; write your own into that file to choose it. Per uid, not per HOME:
# a bot with a HOME of its own (same uid) must read the password the running
# viewer has, not make up a second one. The link needs the desktop owner's
# password, and the owner is whoever runs the X server, so owns its socket;
# root (`docker exec` without -u) can read that file too, another uid cannot.
password_file() { printf '/var/lib/wrap-desktop/%s/password\n' "${1:-$(id -u)}"; }
desktop_uid() { stat -c %u "/tmp/.X11-unix/X$dpy_num" 2>/dev/null || id -u; }
viewer_password() {
  if [ -n "${WRAP_DESKTOP_PASSWORD:-}" ]; then
    printf '%s\n' "$WRAP_DESKTOP_PASSWORD"
    return 0
  fi
  f="$(password_file "$(desktop_uid)")"
  [ -s "$f" ] || return 1
  p="$(head -n 1 "$f")"
  [ -n "$p" ] && printf '%s\n' "$p"
}
# Two starts racing each other both write a candidate; ln never replaces a file,
# so whichever lands first is the password for both. A directory this uid does
# not own is not used (the parent is sticky and world-writable, like /tmp).
ensure_password() {
  [ -z "${WRAP_DESKTOP_PASSWORD:-}" ] || return 0
  f="$(password_file)"
  [ ! -s "$f" ] || return 0
  install -d -m 0700 "${f%/*}" && [ -O "${f%/*}" ] || return 1
  # An empty file left behind (a full disk, a crash) is not a password.
  if [ -e "$f" ] && [ ! -s "$f" ]; then rm -f "$f"; fi
  tmp="$f.$$"
  (umask 077 && od -An -N16 -tx1 /dev/urandom | tr -d ' \n' >"$tmp" && echo >>"$tmp")
  ln "$tmp" "$f" 2>/dev/null || true
  rm -f "$tmp"
}

# voxl on every guest interface (the port publish targets the guest NIC). The
# password reaches it through its environment, which only its own uid can read,
# never through argv, which any uid sees in ps. Audio is the PulseAudio sink's
# monitor (voxl's default output.monitor). WRAP_DESKTOP_VOXL_ARGS adds flags, e.g. --allowed-hosts=NAME to
# answer for a proxy's host name, or --read-only.
start_viewer() {
  ensure_password || { say "viewer: cannot keep a password in $(password_file)"; return 1; }
  pw="$(viewer_password)" || { say "viewer: no password in $(password_file)"; return 1; }
  title="$(cat /proc/sys/kernel/hostname 2>/dev/null || echo wrap) desktop"
  (
    set -f
    export VOXL_PASSWORD="$pw"
    # shellcheck disable=SC2086 # a list of flags, split on purpose
    spawn viewer voxl --addr=0.0.0.0 --port="$WRAP_DESKTOP_VIEWER_PORT" \
      --title="$title" $WRAP_DESKTOP_VOXL_ARGS
  )
}

spawn() { # name cmd...
  name="$1"; shift
  if [ -f "$run_dir/$name.pid" ] && kill -0 "$(cat "$run_dir/$name.pid")" 2>/dev/null; then
    return 0
  fi
  setsid "$@" >>"$log" 2>&1 </dev/null &
  echo $! >"$run_dir/$name.pid"
}

start() {
  install -d -m 0700 "$run_dir" "$XDG_RUNTIME_DIR"
  if ! bus_up; then
    rm -f "$run_dir/dbus.pid" "${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
    spawn dbus dbus-daemon --session --nofork --nopidfile --address="$DBUS_SESSION_BUS_ADDRESS"
    i=0
    until bus_up; do
      i=$((i + 1)); [ "$i" -lt 50 ] || { say "session bus did not come up (see $log)"; return 1; }
      sleep 0.1
    done
  fi
  trust_local_cas
  fresh_desktop=0
  if display_up; then
    say "desktop already up on $DISPLAY"
  else
    rm -f "/tmp/.X${dpy_num}-lock" "/tmp/.X11-unix/X${dpy_num}"
    # -shmem keeps the framebuffer in a SysV segment that voxl reads in place;
    # without it voxl copies every frame out of the server with GetImage.
    spawn xvfb Xvfb "$DISPLAY" -screen 0 "$WRAP_DESKTOP_GEOMETRY" -ac -nolisten tcp \
      +extension GLX +extension RANDR +render -noreset -shmem
    i=0
    until display_up; do
      i=$((i + 1)); [ "$i" -lt 100 ] || { say "Xvfb did not come up (see $log)"; return 1; }
      sleep 0.1
    done
    xset -display "$DISPLAY" s off -dpms >/dev/null 2>&1 || true
    fresh_desktop=1
  fi
  # Accessibility, after X is up: the bus launcher publishes AT_SPI_BUS on the
  # root window, which is how Chromium finds the bus, so it cannot run before
  # the display answers. Only the uid that owns this desktop switches it on —
  # a `sudo -i` login shell runs `start` too, and a launcher of its own would
  # take the root window's address over with a bus the user cannot connect to.
  # Both calls are idempotent and cheap, so every `start` re-checks them.
  if owns_desktop; then
    wrap-a11y enable --quiet || say "accessibility did not switch on (see $log)"
    spawn a11y wrap-a11y watch
  else
    say "desktop belongs to another uid; leaving accessibility to its owner"
  fi
  if [ "$fresh_desktop" = 1 ]; then
    # startxfce4 with DISPLAY and DBUS_SESSION_BUS_ADDRESS set runs xinitrc
    # directly (xfwm4, xfdesktop, panel) instead of launching its own X/dbus.
    spawn xfce startxfce4
    say "desktop up on $DISPLAY ($WRAP_DESKTOP_GEOMETRY)"
  fi
  /opt/wrap/bin/wrap-agent-browser-config
  # Sound, before the viewer and Chrome connect to it; the owner's only, as
  # accessibility is.
  if owns_desktop && ! pulse_up; then
    rm -f "$run_dir/pulse.pid"
    spawn pulse pulseaudio -n -F /etc/wrap/pulse.pa --daemonize=no --use-pid-file=no \
      --exit-idle-time=-1 --log-target=stderr
    i=0
    until pulse_up; do
      i=$((i + 1)); [ "$i" -lt 50 ] || { say "sound server did not come up (see $log)"; break; }
      sleep 0.1
    done
  fi
  # The viewer streams this uid's desktop; another uid's `start` (a `sudo -i`
  # login shell) leaves it to the owner, as it does accessibility.
  if viewer_on && owns_desktop; then
    start_viewer || say "viewer did not start (see $log)"
  fi
  # The one shared Chrome. Explicit --user-data-dir is mandatory: Chrome >= 136
  # refuses --remote-debugging-port on the default profile directory.
  if ! cdp_up; then
    rm -f "$run_dir/chrome.pid"
    install -d "$WRAP_DESKTOP_CHROME_PROFILE"
    # --no-startup-window: the browser process (and CDP) is up, but the
    # desktop stays clean until agent-browser or the dock opens a window.
    spawn chrome wrap-chrome --no-startup-window
    i=0
    until cdp_up; do
      i=$((i + 1)); [ "$i" -lt 150 ] || { say "chrome CDP did not come up (see $log)"; return 1; }
      sleep 0.1
    done
  fi
  # CDP for DevTools/automation outside the guest. Empty or 0 disables it.
  if [ -n "$WRAP_DESKTOP_CDP_PUBLIC_PORT" ] && [ "$WRAP_DESKTOP_CDP_PUBLIC_PORT" != 0 ]; then
    spawn cdp-public socat "TCP-LISTEN:$WRAP_DESKTOP_CDP_PUBLIC_PORT,bind=0.0.0.0,reuseaddr,fork" \
      "TCP:127.0.0.1:$WRAP_DESKTOP_CDP_PORT"
  fi
  if viewer_on; then
    say "view http://127.0.0.1:$WRAP_DESKTOP_VIEWER_PORT/ (via port publish; \`wrap-desktop url\` prints the sign-in link)"
  fi
  say "cdp  http://127.0.0.1:$WRAP_DESKTOP_CDP_PORT  (agent-browser attaches here; :$WRAP_DESKTOP_CDP_PUBLIC_PORT on guest interfaces)"
}

stop() {
  for f in "$run_dir"/*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f")"
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    rm -f "$f"
  done
}

cmd="${1:-start}"; [ $# -gt 0 ] && shift
for a in "$@"; do [ "$a" = "--quiet" ] && quiet=1; done
case "$cmd" in
  start)  start ;;
  stop)   stop ;;
  status)
    if ! display_up; then say "down"; exit 1; fi
    if viewer_on && viewer_up; then say "up on $DISPLAY, viewer on :$WRAP_DESKTOP_VIEWER_PORT"
    else say "up on $DISPLAY, viewer down"; fi ;;
  # The sign-in link: the password rides in ?token=, which voxl's page passes on
  # to its socket. ADDRESS is where the browser reaches the published port
  # (default 127.0.0.1:<viewer port>); a full http(s):// URL, such as an HTTPS
  # proxy in front of it, is used as the base instead.
  url)
    pw="$(viewer_password)" || { echo "wrap-desktop: no viewer password yet; start the desktop first" >&2; exit 1; }
    base="${1:-127.0.0.1:$WRAP_DESKTOP_VIEWER_PORT}"
    case "$base" in *://*) ;; *) base="http://$base" ;; esac
    printf '%s/?token=%s\n' "${base%/}" "$(printf '%s' "$pw" | jq -sRr @uri)" ;;
  # For scripts: curl -u ":$(wrap-desktop password)" localhost:6080/screenshot
  password)
    viewer_password || { echo "wrap-desktop: no viewer password yet; start the desktop first" >&2; exit 1; } ;;
  run)
    # Sleep in the background and `wait`: a foreground sleep defers the TERM
    # trap until it returns, so `docker stop` would always hit its kill timeout.
    trap 'stop; exit 0' INT TERM
    start || say "desktop start incomplete (see $log); retrying"
    while :; do
      if [ "$WRAP_DESKTOP_SUPERVISE_SECONDS" -gt 0 ] 2>/dev/null; then
        sleep "$WRAP_DESKTOP_SUPERVISE_SECONDS" & wait $! || true
        quiet=1; start || true
      else
        sleep 3600 & wait $! || true
      fi
    done ;;
  # Whole-desktop capture (what a human sees in the viewer), for agents that
  # want more than agent-browser's page screenshot.
  screenshot) out="${1:-/tmp/wrap-desktop-$(date +%s).png}"; scrot -o "$out" && printf '%s\n' "$out" ;;
  *) echo "usage: wrap-desktop start [--quiet] | stop | status | run | url [ADDRESS] | password | screenshot [FILE]" >&2; exit 2 ;;
esac
EOF
# Each uid keeps its viewer password in a 0700 directory of its own under this
# sticky parent (see wrap-desktop's password_file).
RUN chmod 0755 /opt/wrap/bin/wrap-desktop \
 && install -d -m 1777 /var/lib/wrap-desktop

# Autostart from login shells (wrap enters every session via `zsh -l`; docker
# `-it` shells too). /etc/profile sources profile.d for sh/bash, and Arch's
# /etc/zsh/zprofile sources /etc/profile. Idempotent: ~1s once, instant after.
RUN cat > /etc/profile.d/wrap-desktop.sh <<'EOF'
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/wrap-desktop-$(id -u)/runtime}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
if [ "${WRAP_DESKTOP_AUTOSTART:-1}" = 1 ] && [ -x /opt/wrap/bin/wrap-desktop ]; then
  /opt/wrap/bin/wrap-desktop start --quiet >/dev/null 2>&1 || true
fi
export AGENT_BROWSER_CONFIG="${AGENT_BROWSER_CONFIG:-/home/user/workspace/agent-browser.json}"
export AGENT_BROWSER_SKILLS_DIR="${AGENT_BROWSER_SKILLS_DIR:-/opt/agent-browser/skill-data}"
export BROWSER="${BROWSER:-wrap-chrome}"
/opt/wrap/bin/wrap-agent-browser-config 2>/dev/null || true
EOF

# Short operator/agent note about what is wired up.
RUN cat > /etc/wrap/desktop.md <<'EOF'
# wrap desktop

- X display `:1` (Xvfb, 1280x800) running XFCE. Autostarts from login shells;
  `wrap-desktop start|stop|status|url|password|screenshot [FILE]` (screenshot =
  whole desktop).
- Local CA anchors (e.g. a TLS-intercepting sandbox's CA) are imported into
  Chrome's NSS store at start, so intercepted hosts load without cert errors.
- One persistent Google Chrome on that desktop (no window until something opens
  one; the dock's Chrome icon opens a window in the same instance), CDP on
  127.0.0.1:9222 (and :9223 on guest interfaces for publishing), profile in
  ~/.config/wrap-chrome. Launch flags (default: WebMCP) come
  from ~/.config/chrome-flags.conf, else /etc/wrap/chrome-flags.conf. First-run, sign-in, sync, default-browser,
  privacy-sandbox, keyring and promo prompts are disabled via managed policies in
  /etc/opt/chrome/policies/managed and /opt/google/chrome/initial_preferences
  (arm64: Chromium, which reads the same files through /etc/chromium).
- agent-browser reads $AGENT_BROWSER_CONFIG (/home/user/workspace/agent-browser.json,
  written once when missing: `{"headed": true, "autoConnect": true}`), so it
  attaches to that Chrome: `agent-browser open https://example.com` acts in the
  same browser a human sees in the viewer and can take over (log in, solve a captcha,
  hand back). Edit that file per workspace; it replaces ~/.agent-browser/config.json.
  `agent-browser doctor` verifies.
- ffmpeg is installed (e.g. record :1 with `ffmpeg -f x11grab -i :1 out.mp4`).
- Sound: a PulseAudio server per desktop with one null sink, `output`; ALSA's default
  device plays into it, the viewer streams it, `ffmpeg -f pulse -i output.monitor` records it.
- The shared Chrome is the default browser: xdg-open, XFCE and $BROWSER open links
  as tabs in it (wrap-chrome).
  Pages' WebMCP tools: `agent-browser webmcp list` / `webmcp invoke <tool>`.
- agent-desktop (installed too, no download on first use) sees and drives the
  desktop's apps through AT-SPI: `agent-desktop list-apps`, `snapshot --app
  <name> -i`, then `click`/`type` with the refs it printed. It needs the
  accessibility bus on; `wrap-a11y status` says whether it is, and
  `wrap-desktop start` switches it on (see below).
- Accessibility: nothing here sets NO_AT_BRIDGE, which would keep GTK from
  loading the bridge. The bus is switched on by setting
  org.a11y.Status.IsEnabled after the session bus is up (`wrap-a11y enable`,
  run by `wrap-desktop start` before XFCE and Chrome). gsettings'
  toolkit-accessibility is an *output* of that property, so setting it alone
  does nothing. `wrap-desktop run` also supervises `wrap-a11y watch`, which
  re-enables the moment a new bus launcher appears, so a launcher that dies
  mid-session recovers without a login. Chrome is told to publish its web
  contents with --force-renderer-accessibility, and a page only appears on the
  tree once a window is open (the dock's icon or `wrap-chrome URL`).
- No window compositor: xfwm4 runs with use_compositing false, because under a
  compositor the X root window holds only the compositor's stage, so a
  whole-screen capture (`wrap-desktop screenshot FILE`, `agent-desktop
  screenshot --screen 0`) cannot see the real windows. A window that is covered
  therefore cannot be captured on its own; capture the screen instead.
- View: voxl, a browser viewer (H.264 over a WebSocket), on :6080 through the
  VM's published ports (wrap: `network.ports: [6080]`; the host side is
  loopback). `wrap-desktop url` prints the sign-in link,
  http://127.0.0.1:6080/?token=<password>. The password is WRAP_DESKTOP_PASSWORD,
  else /var/lib/wrap-desktop/<uid>/password (made up on the first start, kept
  after; `wrap-desktop password` prints it).
  The page decodes with WebCodecs, so open it on localhost/127.0.0.1 or over
  HTTPS; through an HTTPS proxy, pass its host name with
  WRAP_DESKTOP_VOXL_ARGS=--allowed-hosts=NAME. Other sites' pages are refused.
- The viewer's server also answers scripts, with the password as a Bearer token
  or `curl -u ":$(wrap-desktop password)"`: GET localhost:6080/screenshot (PNG),
  and /wait, which returns once the screen has been still for `idle` ms (300)
  or, with `?change`, at the first change: no sleeping after an action.
EOF

# Anything a root build step may have left in the user's home belongs to user.
# Only touch mis-owned paths: chown -R rewrites every file into a new layer.
RUN find "${WRAP_USER_HOME}" \( ! -uid "${WRAP_UID}" -o ! -gid "${WRAP_GID}" \) \
      -exec chown -h "${WRAP_UID}:${WRAP_GID}" {} +

ENV HOME=/home/user USER=user
EXPOSE 6080 9223
CMD ["/opt/wrap/bin/wrap-desktop", "run"]
