#!/bin/bash
# RUY-899 (lead-37): does Flatpak mount *unmaintained* extensions that are symlinks under
# /var/lib/flatpak/extension into a system app, for ADR-038's Play platform on /usr?
# Run in the guest as root:  bash q5-unmaintained-ext.sh [clean]
# Builds a tiny local runtime (the guest's own bash, ls, cat, sleep), an app whose command is in the
# launcher extension point and which declares a runners point with subdirectories, links the
# extensions, and runs the app as root and as a throw-away user. Prints PASS/FAIL/INFO lines.
set -u
work=/var/tmp/spike899
rt=org.ruyaos.Spike899Rt
app=org.ruyaos.Spike899
ext=/var/lib/flatpak/extension
user=spike899
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
info() { echo "INFO: $*"; }

clean() {
    flatpak uninstall --system -y --noninteractive "$app" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force spike899 >/dev/null 2>&1
    rm -rf "$ext/org.ruyaos.Play.Launcher" "$ext"/org.ruyaos.Play.Runner.* "$work"
    id "$user" >/dev/null 2>&1 && userdel -r "$user" >/dev/null 2>&1
}
[ "${1:-}" = clean ] && { clean; echo cleaned; exit 0; }
clean

flatpak --version | sed 's/^/INFO: /'
mkdir -p "$work/rt/usr/bin" "$work/rt/usr/lib64" "$work/rt/files"
for b in bash ls cat sleep readlink; do cp "/usr/bin/$b" "$work/rt/usr/bin/$b" || exit 2; done
cp /usr/bin/bash "$work/rt/usr/bin/sh"
for lib in $(ldd /usr/bin/bash /usr/bin/ls /usr/bin/cat /usr/bin/sleep /usr/bin/readlink | awk '/=> \//{print $3} /ld-linux/{print $1}' | sort -u); do
    cp "$lib" "$work/rt/usr/lib64/" || exit 2
done
printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$rt" "$rt" "$rt" > "$work/rt/metadata"
flatpak build-export --runtime "$work/repo" "$work/rt" stable >/dev/null 2>&1 || { bad "runtime export"; exit 1; }

# The app: nothing of its own but the two mount folders; its command lives in the launcher point.
# No build-finish (it wants the command inside files/); an export/ folder marks it finished.
mkdir -p "$work/app/files/launcher" "$work/app/files/runners" "$work/app/var" "$work/app/export"
cat > "$work/app/metadata" <<EOF
[Application]
name=$app
runtime=$rt/x86_64/stable
sdk=$rt/x86_64/stable
command=/app/launcher/bin/launch

[Extension org.ruyaos.Play.Launcher]
directory=launcher
version=1
no-autodownload=true

[Extension org.ruyaos.Play.Runner]
directory=runners
subdirectories=true
version=1
no-autodownload=true
autodelete=false
EOF
flatpak build-export "$work/repo" "$work/app" stable >/dev/null 2>&1 || { bad "app export"; exit 1; }
flatpak remote-add --system --no-gpg-verify spike899 "$work/repo" >/dev/null 2>&1
flatpak install --system -y --noninteractive spike899 "$app" >/dev/null 2>&1 || { bad "install"; exit 1; }

# The launcher tree (a writable stand-in for /usr/lib/ruyaos/play/launcher: /usr is read-only here).
mkdir -p "$work/launcher/bin"
cat > "$work/launcher/bin/launch" <<'EOF'
#!/bin/sh
echo "launcher-ran uid=$(cat /proc/self/status | while read k v rest; do [ "$k" = Uid: ] && echo $v; done)"
for d in /app/runners/*; do
    [ -e "$d" ] || { echo "runners: none"; break; }
    echo "runner: ${d##*/} -> $(ls -d "$d"/* 2>/dev/null | while read -r f; do printf '%s ' "${f##*/}"; done)"
done
[ -f /app/runners/Test1/runner.json ] && echo "runner.json: $(cat /app/runners/Test1/runner.json)"
EOF
chmod 755 "$work/launcher/bin/launch"
# A runner tree in /var (stand-in) and one that points into the real read-only /usr (bin_t labels).
mkdir -p "$work/runner-test1"
echo '{"format":1,"family":"test","kind":"wine","version":"1.0","arch":"x86_64"}' > "$work/runner-test1/runner.json"

link() { mkdir -p "$ext/$1/x86_64"; ln -sfn "$2" "$ext/$1/x86_64/1"; }
link org.ruyaos.Play.Launcher "$work/launcher"
link org.ruyaos.Play.Runner.Test1 "$work/runner-test1"
link org.ruyaos.Play.Runner.UsrLibexec /usr/libexec

run_as() { # <label> <cmd...>
    local out label=$1
    shift
    out=$("$@" 2>&1)
    set -- "$label"
    echo "$out" | sed "s/^/  [$1] /"
    echo "$out" | grep -q '^launcher-ran' && ok "$1: the command in the linked launcher extension ran" \
        || bad "$1: the launcher extension was not mounted (command missing)"
    echo "$out" | grep -q '^runner: Test1 ' && ok "$1: subdirectories runner Test1 (link into /var) mounted at /app/runners/Test1" \
        || bad "$1: runner Test1 not under /app/runners"
    echo "$out" | grep -q '^runner: UsrLibexec ' && ok "$1: runner linked into read-only /usr mounted" \
        || bad "$1: runner linked into /usr not mounted"
    echo "$out" | grep -q '^runner.json: {' && ok "$1: runner.json readable inside the sandbox" || bad "$1: runner.json not readable"
}
t0=$(date +%s)
run_as root flatpak run --system "$app"
useradd -m "$user" >/dev/null 2>&1
loginctl enable-linger "$user"; sleep 3
# As profiles run apps: a unit in the user's own manager (ruya-session's launch path).
as_user_unit() { systemd-run --user -M "$user@.host" --wait --pipe --quiet flatpak run --system "$app" 2>&1 | cat; }
run_as user as_user_unit
loginctl disable-linger "$user"

flatpak info --system --show-extensions "$app" 2>&1 | sed 's/^/INFO: show-extensions: /' | head -20
avc=$(journalctl --since "@$t0" --no-pager -o cat 2>/dev/null | grep -c 'avc:  denied' || true)
[ "$avc" = 0 ] && ok "no AVC denials during the runs" || bad "$avc AVC denials (journalctl | grep avc)"
# Does an OS-style change (relink to another tree) reach the next run without touching the app?
mkdir -p "$work/launcher2/bin"; sed 's/launcher-ran/launcher-ran v2/' "$work/launcher/bin/launch" > "$work/launcher2/bin/launch"; chmod 755 "$work/launcher2/bin/launch"
ln -sfn "$work/launcher2" "$ext/org.ruyaos.Play.Launcher/x86_64/1"
flatpak run --system "$app" 2>&1 | grep -q 'launcher-ran v2' && ok "a relinked launcher is used at the next run (no re-commit)" || bad "the relinked launcher was not picked up"
clean
[ "$fail" = 0 ] && echo "RESULT: ALL PASS" || echo "RESULT: FAILURES"
exit "$fail"
