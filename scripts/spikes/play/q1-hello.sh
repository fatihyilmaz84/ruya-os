#!/usr/bin/env bash
# Q1: import a package as a generated, locally signed Flatpak app.
# Builds org.ruyaos.Play.Launcher (extension) and play.test.hello (app whose
# payload is a native program), signs both with a throw-away GPG key, adds the
# local repo as a GPG-verified system remote, installs the app (the launcher
# must come along as a related ref), runs it with flatpak run and, if a profile
# is signed in, through org.ruyaos.Session1.Launch.
# Usage: q1-hello.sh   (root, on the test machine)
. "$(dirname "$0")/common.sh"

PROFILE=${PROFILE:-$(busctl --system get-property org.ruyaos.Profiles1 /org/ruyaos/Profiles1 \
    org.ruyaos.Profiles1 ActiveProfile 2>/dev/null | awk '{ gsub(/"/, "", $2); print $2 }')}

# The native payload: a small C program built with the SDK (the console has no
# compiler; the importer would get the binary from the package).
SRC=$WORK/src/hello
mkdir -p "$SRC"
cat > "$WORK/src/hello.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char buf[4096]; FILE *f;
    printf("hello from play.test.hello: pid %d uid %d\n", getpid(), getuid());
    printf("WAYLAND_DISPLAY=%s DISPLAY=%s FLATPAK_ID=%s\n", getenv("WAYLAND_DISPLAY"),
           getenv("DISPLAY"), getenv("FLATPAK_ID"));
    if ((f = fopen("/proc/self/cgroup", "r"))) { while (fgets(buf, sizeof buf, f)) fputs(buf, stdout); fclose(f); }
    fflush(stdout);
    if (argc > 1) sleep(atoi(argv[1]));
    return 0;
}
EOF
if [ ! -x "$SRC/hello" ]; then
    flatpak run --filesystem="$WORK/src" --command=gcc "org.freedesktop.Sdk//$RT_BRANCH" \
        -O2 -o "$SRC/hello" "$WORK/src/hello.c"
fi
cat > "$WORK/src/hello.play.json" <<'EOF'
{ "id": "test.hello", "run": { "command": ["${payload}/hello", "60"], "env": {} } }
EOF

log "build launcher extension"
t=$(now); build_launcher; log "launcher exported in $(elapsed "$t") s"
log "build play.test.hello"
t=$(now)
build_app play.test.hello "$SRC" "$WORK/src/hello.play.json" \
    --socket=wayland --socket=pulseaudio --device=dri --share=ipc
log "app exported in $(elapsed "$t") s"
ostree --repo="$REPO" refs
ostree --repo="$REPO" show "app/play.test.hello/x86_64/stable" | head -8
ensure_remote
flatpak remote-list --system --show-details | grep "$REMOTE" || true
grep -A8 "remote \"$REMOTE\"" /var/lib/flatpak/repo/config

log "install (app only: the launcher must be pulled as a related ref)"
t=$(now); install_ref play.test.hello; log "installed in $(elapsed "$t") s"
flatpak list --system --all --columns=ref,origin | grep -E 'play\.|Play\.' || true
cat /var/lib/flatpak/app/play.test.hello/current/active/metadata

log "flatpak run (as root, no wait)"
flatpak run play.test.hello 0 || echo "flatpak run rc=$?"

if [ -n "$PROFILE" ]; then
    log "Session1.Launch play.test.hello as $PROFILE"
    busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 \
        Launch ss play.test.hello "$PROFILE"
    sleep 4
    busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 ListRunning
    U=ruya-$PROFILE
    journalctl --no-pager -q --since=-1min _COMM=hello 2>/dev/null | tail -5 || true
    systemctl --user -M "$U@.host" list-units --plain --no-legend 'app-flatpak-play.test.hello-*' 'ruya-app-*hello*'
else
    log "no profile signed in: Session1 launch skipped"
fi
