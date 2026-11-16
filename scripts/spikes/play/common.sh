#!/usr/bin/env bash
# RUY-91 (T-229) spike helpers: build a generated play.* Flatpak app and the
# org.ruyaos.Play.Launcher extension by hand, sign them with a throw-away
# device key and serve them from a local OSTree repo as a GPG-verified system
# remote. Sourced by the q*.sh scripts. Runs as root on the test machine.
set -euo pipefail

WORK=${WORK:-/var/tmp/ruy91}
export GNUPGHOME=${GNUPGHOME:-$WORK/gnupg}
REPO=${REPO:-$WORK/repo}
REMOTE=${REMOTE:-ruy91-local}
RUNTIME=${RUNTIME:-org.freedesktop.Platform}
RT_BRANCH=${RT_BRANCH:-25.08}
LOGS=$WORK/logs
mkdir -p "$WORK" "$LOGS"

log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }

# Seconds since the epoch with nanoseconds, for timings.
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }

# Bytes used on the filesystem that holds $1.
fs_used() { df -B1 --output=used "$1" | tail -1 | tr -d ' '; }

# A throw-away signing key (no passphrase), created once per run directory.
key_id() {
    if [ ! -s "$WORK/key.id" ]; then
        mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
        gpg --batch --pinentry-mode loopback --passphrase '' \
            --quick-gen-key 'RuyaOS Play device key (RUY-91 spike)' ed25519 sign never >&2
        gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/ { print $10; exit }' > "$WORK/key.id"
        gpg --batch --export "$(cat "$WORK/key.id")" > "$WORK/key.gpg"
    fi
    cat "$WORK/key.id"
}

ensure_repo() {
    # archive-z2 is what an HTTP remote needs; bare-user-only lets a file://
    # pull and the deploy hardlink objects on the same filesystem.
    [ -d "$REPO/objects" ] || ostree init --repo="$REPO" --mode="${REPO_MODE:-archive-z2}" >&2
}

# The system remote for the local repo, GPG verification on (never --no-gpg-verify).
ensure_remote() {
    key_id >/dev/null
    if ! flatpak remotes --system --columns=name | grep -qx "$REMOTE"; then
        flatpak remote-add --system --gpg-import="$WORK/key.gpg" \
            --title='RUY-91 device-local imports' "$REMOTE" "file://$REPO" >&2
    fi
}

# export_dir <build-dir> <branch> : sign and commit a finished build dir.
export_dir() {
    local dir=$1 branch=$2; shift 2
    ensure_repo
    flatpak build-export "$@" --gpg-sign="$(key_id)" --gpg-homedir="$GNUPGHOME" \
        "$REPO" "$dir" "$branch" >&2
}

# The shared launcher extension: one script, mounted by every play.* app at
# /app/launcher. It reads /app/play.json (run.command argv, run.env) and execs.
build_launcher() {
    local d=$WORK/build/launcher
    rm -rf "$d"
    flatpak build-init --type=extension "$d" org.ruyaos.Play.Launcher \
        "$RUNTIME" "$RUNTIME" "$RT_BRANCH" >&2
    mkdir -p "$d/files/bin"
    cat > "$d/files/bin/ruya-play-launch" <<'EOF'
#!/bin/sh
# Spike launcher: argv and env from /app/play.json, placeholders ${payload} and ${data}.
exec python3 - "$@" <<'PY'
import json, os, re, sys
m = json.load(open("/app/play.json"))
run = m["run"]
data = os.environ.get("XDG_DATA_HOME", "")
subst = {"${payload}": "/app/payload", "${data}": data, "${prefix}": data + "/prefix"}
def s(a):
    for k, v in subst.items():
        a = a.replace(k, v)
    return re.sub(r"\$\{component:([a-z0-9-]+)\}", r"/app/components/\1", a)
argv = [s(a) for a in run["command"]] + sys.argv[1:]
env = dict(os.environ)
for k, v in run.get("env", {}).items():
    env[k] = s(v)
for step in run.get("setup", []):
    print("ruya-play-launch: setup", step, file=sys.stderr, flush=True)
    rc = os.spawnvpe(os.P_WAIT, s(step[0]), [s(a) for a in step], env)
    print("ruya-play-launch: setup rc", rc, file=sys.stderr, flush=True)
print("ruya-play-launch: exec", argv, file=sys.stderr, flush=True)
os.execvpe(argv[0], argv, env)
PY
EOF
    chmod 755 "$d/files/bin/ruya-play-launch"
    export_dir "$d" 1
}

# build_app <id> <src-dir> <play.json> [finish-args...]
# <src-dir> becomes /app/payload, <play.json> /app/play.json. Every app declares
# the launcher extension point and runs the launcher as its command.
build_app() {
    local id=$1 src=$2 manifest=$3; shift 3
    local d=$WORK/build/$id
    rm -rf "$d"
    flatpak build-init "$d" "$id" "$RUNTIME" "$RUNTIME" "$RT_BRANCH" >&2
    # APP_ROOT_FROM=<dir>: a tree copied to /app first (a runner built for
    # prefix /app, e.g. Flathub's Wine). COMPONENTS="name=dir ...": bundled
    # components at /app/components/<name>. Both hardlinked (same filesystem).
    if [ -n "${APP_ROOT_FROM:-}" ]; then cp -al "$APP_ROOT_FROM/." "$d/files/"; fi
    local c
    for c in ${COMPONENTS:-}; do
        mkdir -p "$d/files/components"
        cp -al "${c#*=}" "$d/files/components/${c%%=*}"
    done
    mkdir -p "$d/files/launcher"
    if [ -n "$src" ]; then
        if [ -n "${LINK_PAYLOAD:-}" ]; then
            # Hardlinked staging: no second copy of the payload in the build dir.
            cp -al "$src" "$d/files/payload"
        else
            cp -a "$src" "$d/files/payload"
        fi
    fi
    cp "$manifest" "$d/files/play.json"
    # Every extension point needs its mount directory in the (read-only) /app,
    # or bwrap fails: "Can't mkdir parents for /app/lib/i386-linux-gnu".
    local a
    for a in "$@"; do
        case $a in --extension=*=directory=*) mkdir -p "$d/files/${a##*=directory=}" ;; esac
    done
    flatpak build-finish "$d" --command=/app/launcher/bin/ruya-play-launch \
        --extension=org.ruyaos.Play.Launcher=directory=launcher \
        --extension=org.ruyaos.Play.Launcher=version=1 \
        --extension=org.ruyaos.Play.Launcher=no-autodownload=false \
        "$@" >&2
    export_dir "$d" stable ${EXPORT_ARGS:-}
}

# prun <profile> <cmd...>: run a command the way ruya-session runs an app: a
# transient unit of the profile user's manager with the profile's Wayland
# socket and sound server (03 §4.1), output piped back here. Output goes
# through a pipe: --pipe hands our fds to the user's manager, and a file under
# /var/tmp as stdout makes the call fail ("Remote peer disconnected", SELinux).
prun() {
    local u=ruya-$1; shift
    systemd-run --user --machine="$u@.host" --wait --collect --pipe --quiet -p Type=exec \
        -E WAYLAND_DISPLAY="/run/ruya-wayland/$u" -E SDL_VIDEODRIVER=wayland \
        -E XDG_SESSION_TYPE=wayland -E PULSE_SERVER="unix:/run/ruya-pulse/$u/native" -- "$@" \
        < /dev/null 2>&1 | cat
    return "${PIPESTATUS[0]}"
}

# Flatpak's own system install of a ref from the local remote.
install_ref() { flatpak install --or-update -y --system --noninteractive "$REMOTE" "$@" >&2; }
