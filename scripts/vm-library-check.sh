#!/usr/bin/env bash
# modes: check choicejudge clean installations installjudge play playid playjudge runners runnersjudge scanjudge security seed steam steamids
# Checks ruya-library (org.ruyaos.Library1, T-112 / T-163 / T-183) inside a running VM, as root. It builds a
# tiny signed Flatpak repository (one runtime, a game and an app, no download, like
# vm-store-check.sh), adds it through Store1, installs and uninstalls through Store1 and watches
# Library1 over the system bus. Copy and run:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-library-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-library-check.sh [check|seed|security|clean]
#   check     the whole cycle (install, title, update without Rescan, ItemsChanged, uninstall,
#             refused callers), cleans up after (also when it stops early: an exit trap, T-193)
#   seed      leaves the test game and app installed, for a screenshot of the shell (clean removes;
#             a seed that failed cleans up itself)
#   clean     removes the test remote, apps and repository
#   play      RUY-852: installs the .play sample through Play1 (developer mode, from incoming/),
#             then Library1 must list it with play true, its title, the art of its package as
#             paths ruya-shell can read, genres, a tier when ruya-play wrote trust.json, no
#             play_signer_key_id (the sample installs unsigned) and play_screenshots equal to the
#             screenshots its play.json declares, in order, as paths ruya-shell can read (RUY-886);
#             removes the sample and puts developer mode back (also on a failure). The sample is
#             installed as "<its id>_library" (RUY-877), so this passes after vm-play-check.sh in
#             any order.
#             vm-library-check.sh play [/root/hello-play-native.play.zip]  (the sample as for
#             vm-play-check.sh; copy vm-play-check.sh next to this script, its `withid` mode
#             writes the package's new id, RUY-878); `playid <id>` prints the id the play mode
#             installs under (host fixtures); `playjudge <id> [screenshots [key id]]` reads ListItems as busctl --json=short on stdin
#             (host fixtures, scripts/test-vm-checks.sh)
#   runners   RUY-959: Library1 ListRunners (as ruya-shell) lists the image's GE-Proton with its
#             kind and version; then the .play sample is installed as for `play` and a profile's
#             runner choice for it (SetRunnerChoice "system") is stored in
#             /var/lib/ruyaos/library/<profile>.json, survives `systemctl restart ruya-library`
#             and is cleared by "package" (no file left); an unknown choice is "invalid", an id that
#             is not installed "unknown". Removes the sample after.
#             vm-library-check.sh runners [/root/hello-play-native.play.zip]
#             `runnersjudge` judges ListRunners as busctl --json=short on stdin (host fixtures);
#             `choicejudge <choice>` judges a GetRunnerChoice reply (busctl's text, `ss "ok" "<choice>"`:
#             the contract returns status and choice) on stdin, PASS when it is ok with that choice
#   steam     RUY-1056 (ADR-045): a Steam folder in the first profile's home (two games, a Proton tool,
#             a manifest that is a link); signed in as that profile ListItems has exactly the two steam:
#             items; a switch to a second profile sends ItemsChanged and leaves none; PutProfileItems and
#             SetActiveProfile from ruya-shell are AccessDenied; ruya-library keeps ProtectHome=yes; after
#             `systemctl restart ruya-library` the items come back without a sign-in; a unit with the
#             reader's properties starts in the profile's manager, with its systemd-analyze --user
#             security; and as the reader's unit (RUY-1102) a write to the home and to /run/user/<uid>
#             fails on a read-only file system and socket() of every family ends the process.
#             Needs a profile (vm-goto.ps1 home, admin PIN 1234); makes a second one when there is
#             none and removes it, and the folder, after (also on a failure).
#             `steamids` prints the steam: ids of a ListItems reply (busctl's text) on stdin (host fixtures);
#             `scanjudge` judges the sandbox probe's output on stdin (host fixtures)
#   installations  RUY-137: one game, two installations. Installs the test game (Flatpak, through Store1) and the
#             .play sample (as for `play`), signs in the first profile, links them (LinkInstallations as
#             ruya-shell: one game under the Flatpak's id, confidence confirmed), sets the Flatpak as the
#             preferred one (SetPreferredInstallation: the game's launch is the Flatpak's), finds both in
#             /var/lib/ruyaos/library/<profile>.json (format 2), restarts ruya-library and finds the
#             state back once ruya-session has set the active profile again, then UnlinkInstallation splits
#             them (two games, nothing of them left in the file). Removes both after (also on a failure).
#             vm-library-check.sh installations [/root/hello-play-native.play.zip] (vm-play-check.sh next
#             to it, as for `play`). Needs a profile (vm-goto.ps1 home, admin PIN 1234).
#             `installjudge linked <a> <b> <preferred>` | `installjudge apart <a> <b>` judges ListItems as
#             busctl --json=short on stdin (host fixtures)
#   security  see vm-security-check.sh (unit hardening)
# Boot the VM with plain smoke-test.ps1 -Keep (or -Work -Keep for the screenshot).
set -u
svc=org.ruyaos.Library1
path=/org/ruyaos/Library1
ifc=org.ruyaos.Library1
store=org.ruyaos.Store1
spath=/org/ruyaos/Store1
game=org.ruyaos.TestGame
notes=org.ruyaos.TestNotes
rt=org.ruyaos.TestRuntime
remote=ruyaos-libtest
work=/var/lib/ruya-library-test
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

as_shell() { runuser -u ruya-shell -- "$@"; }
list_items() { as_shell busctl --system call "$svc" "$path" "$ifc" ListItems; }
# The text keys of one item's record as busctl's text prints them ("title" s "Test Game"), one per line:
# read from the JSON reply, so a game's nested installations (RUY-137) never mix with another record.
record_of() {
    list_items_json | python3 -c '
import json, sys
def val(v):
    return v.get("data") if isinstance(v, dict) and "type" in v and "data" in v else v
for rec in (json.load(sys.stdin).get("data") or [[]])[0]:
    if val(rec.get("id")) == sys.argv[1]:
        for k, v in sorted(rec.items()):
            if isinstance(v, dict) and v.get("type") == "s":
                print("\"%s\" s \"%s\"" % (k, v["data"]))
' "flatpak:$1"
}
signals() { local n; n="$(grep -c '"member":"ItemsChanged"' "$work/signals.log" 2>/dev/null)"; echo "${n:-0}"; }

# make_app <id> <name> <categories>: an app with a desktop entry in the repository. Every call
# builds the directory from scratch (build-finish refuses one that is already finalized), so a
# second call exports a new commit on `stable`.
make_app() {
    local id="$1" name="$2" cats="$3" dir="$work/app-$1"
    rm -rf "$dir"
    mkdir -p "$dir/files/bin" "$dir/files/share/applications" "$dir/files/share/metainfo" "$dir/var"
    printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=hello\n' "$id" "$rt" "$rt" > "$dir/metadata"
    printf '#!/bin/sh\necho hello\n' > "$dir/files/bin/hello"; chmod 755 "$dir/files/bin/hello"
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=hello\nCategories=%s\n' "$name" "$cats" > "$dir/files/share/applications/$id.desktop"
    cat > "$dir/files/share/metainfo/$id.metainfo.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$id</id>
  <name>$name</name>
  <summary>A tiny app for the library check</summary>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <developer_name>RuyaOS</developer_name>
  <description><p>Nothing to see.</p></description>
</component>
EOF
    flatpak build-finish --command=hello "$dir" || return 1
    flatpak build-export $sign "$work/repo" "$dir" stable || return 1
}

build_repo() {
    rm -rf "$work"; mkdir -p "$work/gpg" "$work/rt/usr/share/ruya-test" "$work/rt/files" "$work/rt/var"
    chmod 700 "$work/gpg"
    gpg --homedir "$work/gpg" --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "ruya-library-test <test@example.org>" default default never >/dev/null 2>&1 || return 1
    key="$(gpg --homedir "$work/gpg" --list-keys --with-colons | awk -F: '/^pub/ {k=$5} END {print k}')"
    echo hello > "$work/rt/usr/share/ruya-test/hello"
    printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$rt" "$rt" "$rt" > "$work/rt/metadata"
    sign="--gpg-sign=$key --gpg-homedir=$work/gpg"
    flatpak build-export --runtime $sign "$work/repo" "$work/rt" stable || return 1
    make_app "$game" "Test Game" "Game;ArcadeGame;" || return 1
    make_app "$notes" "Test Notes" "Utility;" || return 1
    flatpak build-update-repo $sign "$work/repo" || echo "(build-update-repo warned: appstream data may be missing)"
    {
        printf '[Flatpak Repo]\nTitle=Library check\nUrl=file://%s/repo\n' "$work"
        printf 'GPGKey=%s\n' "$(gpg --homedir "$work/gpg" --export "$key" | base64 -w0)"
    } > "$work/test.flatpakrepo"
}

add_remote() {
    local out
    out="$(busctl --system call "$store" "$spath" "$store" AddRemote ss "$remote" "file://$work/test.flatpakrepo")"
    case "$out" in 's "ok"') ok "AddRemote of the test repository by root";; *) bad "AddRemote: $out"; return 1;; esac
    # The catalogue is read again in the background; Install needs the app in it.
    local n=0
    until as_shell busctl --system call "$store" "$spath" "$store" Search 'sa{sv}' "TestGame" 0 | grep -q "$game" || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    echo "the test apps were in the store catalogue after about $n s"
}

# install_app <id>: queue through Store1 as ruya-shell
install_app() {
    local out
    out="$(as_shell busctl --system call "$store" "$spath" "$store" Install s "$1")"
    case "$out" in 'ss "ok"'*) ok "Install $1 queued";; *) bad "Install $1: $out"; return 1;; esac
}

# wait_listed <id> <yes|no> <seconds>: until ListItems has (or has not) flatpak:<id>
wait_listed() {
    local n=0
    while [ "$n" -lt "$3" ]; do
        if list_items | grep -q "\"flatpak:$1\""; then [ "$2" = yes ] && { echo "$n"; return 0; }
        else [ "$2" = no ] && { echo "$n"; return 0; }; fi
        sleep 1; n=$((n + 1))
    done
    return 1
}

# wait_record <id> <text> <seconds>: until the item's record contains <text> (no Rescan is sent)
wait_record() {
    local n=0
    while [ "$n" -lt "$3" ]; do
        if record_of "$1" | grep -q "$2"; then echo "$n"; return 0; fi
        sleep 1; n=$((n + 1))
    done
    return 1
}

# --- RUY-852: a .play app in the library -----------------------------------------------------------
play_svc=org.ruyaos.Play1
play_obj=/org/ruyaos/Play1
play_state=/var/lib/ruya-play
play_id=""
play_dev=""

# play_fields <app id>: ListItems (busctl --json=short) on stdin -> one "key=value" line per fact of
# the item flatpak:play.<id>, read by key; "found=no" when it is not listed. The art is
# "art.<role>=<path>".
play_fields() {
    python3 -c '
import json, sys
want = "flatpak:play." + sys.argv[1]
def val(v):
    return v.get("data") if isinstance(v, dict) and "type" in v and "data" in v else v
doc = json.load(sys.stdin)
for rec in (doc.get("data") or [[]])[0]:
    if val(rec.get("id")) != want:
        continue
    print("found=yes")
    for k in ("play", "title", "controller", "play_tier", "play_signer", "play_signer_key_id",
              "play_runner", "play_runner_source", "play_runner_tested", "play_resolve_error"):
        if k in rec:
            v = val(rec[k])
            print("%s=%s" % (k, str(v).lower() if isinstance(v, bool) else v))
    if "genres" in rec:
        print("genres=%s" % ",".join(val(rec["genres"])))
    if "players" in rec:
        print("players=%s-%s" % tuple(val(rec["players"])))
    for role, path in sorted((val(rec.get("art")) or {}).items()):
        print("art.%s=%s" % (role, path))
    for i, path in enumerate(val(rec.get("play_screenshots")) or []):
        print("shot.%d=%s" % (i, path))
    sys.exit(0)
print("found=no")
' "$1"
}

# judge_readable <app id> <what> <path>: the path lies in the app's deployment and ruya-shell can read it
judge_readable() {
    case "$3" in
        /var/lib/flatpak/app/play."$1"/*|"${PLAY_FIXTURE_ROOT:-/nonexistent}"/*) ;;
        *) bad "$2 is outside the deployment: $3"; return ;;
    esac
    as_shell test -r "$3" && ok "ruya-shell can read $2" || bad "ruya-shell cannot read $2: $3"
}

# judge_signer_key_id <fields> <expected key id>: play_signer_key_id is absent when the expected id
# is empty (an unsigned sample), else it is exactly that id (32 hex, 05 section 9)
judge_signer_key_id() {
    local got
    got="$(echo "$1" | sed -n 's/^play_signer_key_id=//p')"
    if [ -z "$2" ]; then
        [ -z "$got" ] && ok "an unsigned sample has no play_signer_key_id" || bad "play_signer_key_id is '$got' for an unsigned sample"
    else
        [ "$got" = "$2" ] && echo "$got" | grep -Eq '^[0-9a-f]{32}$' && ok "play_signer_key_id is the signer's key id" || bad "play_signer_key_id is '$got', not $2"
    fi
}

# judge_screenshots <app id> <fields> <expected count>: play_screenshots lists the sample's
# screenshots (the 1080p files, screenshot-<n>-1080.*, n rising), as paths ruya-shell can read;
# the key is absent when the sample has none
judge_screenshots() {
    local shots n=0 line path name idx prev=-1 ordered=yes
    shots="$(echo "$2" | grep '^shot\.' || true)"
    [ -n "$shots" ] && n="$(echo "$shots" | wc -l)"
    [ "$n" = "$3" ] && ok "play_screenshots lists $3 screenshot(s)" || { bad "play_screenshots lists $n, the sample has $3"; return; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        path="${line#*=}"; name="${path##*/}"
        idx="$(echo "$name" | sed -n 's/^screenshot-\([0-9]\{1,\}\)-1080\..*$/\1/p')"
        { [ -n "$idx" ] && [ "$idx" -gt "$prev" ]; } || ordered=no
        [ -n "$idx" ] && prev="$idx"
        judge_readable "$1" "screenshot ${line%%=*}" "$path"
    done <<< "$shots"
    [ "$ordered" = yes ] && ok "the screenshots are the 1080p files in order" || bad "the screenshots are not screenshot-<n>-1080 files in rising order"
}

# judge_runner <fields>: the sample is a native game, so the launcher's own resolution
# (ruya-library's dry run, RUY-903) has no runner for it and nothing to refuse. A play_resolve_error
# here means ruya-library could not read the deployment the way the launcher will (the sentence is
# printed), a play_runner* key that the resolution invented a runner.
judge_runner() {
    local err
    err="$(echo "$1" | sed -n 's/^play_resolve_error=//p')"
    [ -z "$err" ] && ok "the launch would not refuse the sample (no play_resolve_error)" || bad "play_resolve_error for the sample: $err"
    echo "$1" | grep -q '^play_runner' && bad "a native sample has a play_runner key" || ok "a native sample has no play_runner keys"
}

# play_judge <app id> [screenshots in the sample] [expected signer key id]: ListItems on stdin;
# PASS/FAIL lines, sets $fail
play_judge() {
    local f line role path
    f="$(play_fields "$1")"
    echo "$f"
    echo "$f" | grep -q '^found=yes$' && ok "play.$1 is in ListItems" || { bad "play.$1 is not in ListItems"; return; }
    echo "$f" | grep -q '^play=true$' && ok "the item says play true" || bad "play is not true"
    echo "$f" | grep -q '^title=.\+' && ok "the item has the title from play.json" || bad "no title"
    echo "$f" | grep -q '^genres=' && ok "the item lists genres" || bad "no genres key"
    echo "$f" | grep -q '^art\.icon=' && ok "the art has the icon role" || bad "no icon in the art"
    while IFS= read -r line; do
        role="${line#art.}"; role="${role%%=*}"; path="${line#*=}"
        judge_readable "$1" "the $role art" "$path"
    done < <(echo "$f" | grep '^art\.')
    judge_signer_key_id "$f" "${3:-}"
    judge_screenshots "$1" "$f" "${2:-0}"
    judge_runner "$f"
    # A tier is present only when ruya-play wrote trust.json; when it is there it is a known one.
    if echo "$f" | grep -q '^play_tier='; then
        echo "$f" | grep -Eq '^play_tier=(official|developer|unverified)$' && ok "the tier is a known one" || bad "unknown tier"
    else
        echo "(no play_tier: trust.json is not written yet, or unreadable)"
    fi
}

# The id the play mode installs the sample under (RUY-877): vm-play-check.sh's one id-suffix rule.
play_pkg_id() { bash "$(dirname "$0")/vm-play-check.sh" pkgid "$1" library; }

# play_install <zip>: installs the sample through Play1 under its own id; sets $play_id and
# $shots (the screenshots its play.json declares). Returns 1 (with a FAIL line) when it did not.
play_install() {
    local zip="$1" out job n line playcheck
    [ -f "$zip" ] || { bad "no sample at $zip"; return 1; }
    playcheck="$(dirname "$0")/vm-play-check.sh"
    [ -f "$playcheck" ] || { bad "no $playcheck: copy vm-play-check.sh next to this script"; return 1; }
    # The sample's id and the number of screenshots its play.json declares (the sample installs unsigned).
    { read -r play_id; read -r shots; } < <(python3 - "$zip" <<'PY'
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
name = next(n for n in z.namelist() if n.endswith("play.json") and n.count("/") <= 1)
m = json.loads(z.read(name))
print(m["id"])
print(len(m.get("art", {}).get("screenshots", [])))
PY
)
    play_dev="$(busctl --system --json=short call "$play_svc" "$play_obj" "$play_svc" GetDeveloperMode | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print("true" if d and d[0]=="ok" and d[1] else "false")')"
    busctl --system call "$play_svc" "$play_obj" "$play_svc" SetDeveloperMode 'ba{sv}' true 1 admin_approved b true >/dev/null || { bad "cannot turn developer mode on"; return 1; }
    mkdir -p "$play_state/incoming"
    # RUY-877: its own id ("<id>_library"), so vm-play-check.sh's records for the sample's id never
    # meet this unsigned install (ruya-play keeps a signer's trust record after an uninstall).
    play_id="$(play_pkg_id "$play_id")" || { bad "no package id for the sample $play_id"; return 1; }
    # The one id rewrite lives in vm-play-check.sh (RUY-878), which sits next to this script.
    bash "$playcheck" withid "$zip" "$play_state/incoming/vm-library-check.play.zip" "$play_id" \
        || { bad "$playcheck withid: no copy of the sample with the id $play_id"; return 1; }
    chmod 0600 "$play_state/incoming/vm-library-check.play.zip"
    out="$(busctl --system --json=short call "$play_svc" "$play_obj" "$play_svc" Install 'sa{sv}' "$play_state/incoming/vm-library-check.play.zip" 1 admin_approved b true)"         || { bad "Play1.Install failed"; return 1; }
    job="$(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d[1] if len(d)>1 else "")')"
    n=0
    while [ "$n" -lt 300 ]; do
        line="$(busctl --system --json=short call "$play_svc" "$play_obj" "$play_svc" ListJobs | python3 -c '
import json, sys
def val(v):
    return v.get("data") if isinstance(v, dict) and "type" in v and "data" in v else v
for j in (json.load(sys.stdin).get("data") or [[]])[0]:
    if val(j.get("id")) == sys.argv[1]:
        print(val(j.get("state")), val(j.get("status")))
' "$job")"
        case "$line" in finished\ *) break ;; esac
        sleep 1; n=$((n + 1))
    done
    [ "$line" = "finished ok" ] && ok "the sample installs" || { bad "the sample install: ${line:-timeout}"; return 1; }
    n=0
    until list_items_json | play_fields "$play_id" | grep -q '^found=yes$' || [ "$n" -ge 60 ]; do sleep 1; n=$((n + 1)); done
}

# play_check <zip>
play_check() {
    local json
    play_install "$1" || return
    json="$(list_items_json)"
    play_judge "$play_id" "$shots" "" <<< "$json" # not a pipe: $fail must survive
}

# runners_judge: Library1 ListRunners as busctl --json=short on stdin. Every runner has a family,
# a kind and a version; the image's GE-Proton (family proton-ge, kind proton) is one of them.
runners_judge() {
    local f
    f="$(python3 -c '
import json, sys
def val(v):
    return v.get("data") if isinstance(v, dict) and "type" in v and "data" in v else v
data = json.load(sys.stdin).get("data") or [[]]
for r in data[0]:
    r = {k: val(v) for k, v in r.items()}
    print("\t".join(str(r.get(k) or "") for k in ("family", "kind", "version", "licence", "source_url")))
')"
    echo "$f"
    [ -n "$f" ] && ok "ListRunners lists $(echo "$f" | wc -l) runner(s)" || { bad "ListRunners lists no runner"; return; }
    echo "$f" | awk -F'\t' '$1 == "" || $2 == "" || $3 == "" { bad = 1 } END { exit bad }' && ok "every runner has a family, a kind and a version" || bad "a runner without a family, kind or version"
    echo "$f" | awk -F'\t' '$1 == "proton-ge" && $2 == "proton" && $3 ~ /^GE-Proton/ { found = 1 } END { exit !found }' && ok "the image's GE-Proton is listed" || bad "no proton-ge runner of kind proton with a GE-Proton version"
}

choice_of() { as_shell busctl --system call "$svc" "$path" "$ifc" GetRunnerChoice ss "$1" "$2"; }
# choice_judge <choice>: a GetRunnerChoice reply on stdin (two strings, status and choice) is ok with <choice>.
choice_judge() { [ "$(cat)" = "ss \"ok\" \"$1\"" ]; }
# choice_is <profile> <id> <choice>
choice_is() { choice_of "$1" "$2" 2>/dev/null | choice_judge "$3"; }
set_choice() { as_shell busctl --system call "$svc" "$path" "$ifc" SetRunnerChoice sss "$1" "$2" "$3"; }

# runners_check <zip>
runners_check() {
    local id prof=vmcheck file=/var/lib/ruyaos/library/vmcheck.json n=0 got listing
    listing="$(mktemp)"
    as_shell busctl --system --json=short call "$svc" "$path" "$ifc" ListRunners > "$listing" 2>&1 || bad "ListRunners failed: $(cat "$listing")"
    runners_judge < "$listing"
    rm -f "$listing"
    play_install "$1" || return
    id="flatpak:play.$play_id"
    got="$(set_choice "$prof" "$id" system)"
    [ "$got" = 's "ok"' ] && ok "SetRunnerChoice system: ok" || bad "SetRunnerChoice system: $got"
    choice_is "$prof" "$id" system && ok "GetRunnerChoice: system" || bad "GetRunnerChoice: $(choice_of "$prof" "$id")"
    [ "$(stat -c '%U %a' "$file" 2>/dev/null)" = "ruya-library 600" ] && ok "the choice is in $file (ruya-library, 0600)" || bad "$file: $(stat -c '%U %a' "$file" 2>&1)"
    systemctl restart ruya-library
    until choice_is "$prof" "$id" system || [ "$n" -ge 30 ]; do sleep 1; n=$((n + 1)); done
    choice_is "$prof" "$id" system && ok "the choice survives a restart of ruya-library" || bad "after a restart GetRunnerChoice: $(choice_of "$prof" "$id")"
    [ "$(set_choice "$prof" "$id" proton)" = 's "invalid"' ] && ok "an unknown choice is invalid" || bad "SetRunnerChoice proton: $(set_choice "$prof" "$id" proton)"
    [ "$(set_choice "$prof" "flatpak:play.not.installed" system)" = 's "unknown"' ] && ok "an id that is not installed is unknown" || bad "SetRunnerChoice of no item: $(set_choice "$prof" "flatpak:play.not.installed" system)"
    [ "$(set_choice "$prof" "$id" package)" = 's "ok"' ] && choice_is "$prof" "$id" package && ok "package clears the choice" || bad "SetRunnerChoice package: $(choice_of "$prof" "$id")"
    [ ! -e "$file" ] && ok "no choice left, no file" || bad "$file is left"
}
list_items_json() { as_shell busctl --system --json=short call "$svc" "$path" "$ifc" ListItems; }

# --- steam (RUY-1056, ADR-045): the per-profile Steam reader
# steam_ids: the distinct "steam:<digits>" item ids of a ListItems reply (busctl's text) on stdin, sorted.
steam_ids() { grep -o '"steam:[0-9]*"' | tr -d '"' | sort -u; }
# The reader's unit properties, as spawner::PROFILE_SCAN_PROPERTIES in ruya-session has them
# (test-vm-checks.sh keeps the two the same): the security report and the sandbox probe run in a unit
# built like the reader's.
scan_properties="MemoryMax=512M TasksMax=16 NoNewPrivileges=yes PrivateNetwork=yes ProtectSystem=strict ProtectHome=read-only PrivateTmp=yes SystemCallFilter=@system-service SystemCallFilter=~@network-io MemoryDenyWriteExecute=yes LockPersonality=yes RestrictNamespaces=yes CapabilityBoundingSet="
# The reader's RuntimeMaxSec, spawner::PROFILE_SCAN_RUNTIME_SECS (test-vm-checks.sh keeps the two the same).
scan_runtime=20
# The sandbox probe (RUY-1102), run as the reader's unit: a write to the home and to /run/user/<uid>,
# a read of the home, and socket() of four families (python3 imports socket first, the control).
scan_probe='ulimit -c 0
for d in "home=$HOME" "runuser=/run/user/$(id -u)"; do
    f="${d#*=}/.ruya-scan-probe"
    if err="$( { : > "$f"; } 2>&1 )"; then rm -f "$f"; echo "write ${d%%=*}: written"
    else case "$err" in *"Read-only file system"*) echo "write ${d%%=*}: read-only";; *) echo "write ${d%%=*}: other: $err";; esac; fi
done
ls -d "$HOME/." >/dev/null 2>&1 && echo "read home: ok" || echo "read home: failed"
python3 -c "import socket" >/dev/null 2>&1; echo "python: rc$?"
for fam in AF_UNIX AF_INET AF_INET6 AF_NETLINK; do
    python3 -c "import socket, sys; f = getattr(socket, sys.argv[1]); socket.socket(f, socket.SOCK_RAW if f == socket.AF_NETLINK else socket.SOCK_DGRAM).close()" "$fam" >/dev/null 2>&1
    echo "socket $fam: rc$?"
done'
# scan_judge: judges the probe's output on stdin (host fixtures in test-vm-checks.sh). Both writes must
# fail on a read-only file system, the home must still read, and every socket() must end python3 by
# SIGSYS (rc159: the system-call filter's kill), after a python3 that only imports socket ran (rc0).
scan_judge() {
    local out ok=1 d fam
    out="$(cat)"
    for d in home runuser; do
        echo "$out" | grep -qx "write $d: read-only" || { echo "FAIL: a write to the $d as the reader's unit: $(echo "$out" | grep "^write $d" || echo 'not tried')"; ok=0; }
    done
    echo "$out" | grep -qx 'read home: ok' || { echo "FAIL: the reader's unit cannot read the home"; ok=0; }
    echo "$out" | grep -qx 'python: rc0' || { echo "FAIL: python3 does not run in the reader's unit: $(echo "$out" | grep '^python')"; ok=0; }
    for fam in AF_UNIX AF_INET AF_INET6 AF_NETLINK; do
        echo "$out" | grep -qx "socket $fam: rc159" || { echo "FAIL: socket($fam) in the reader's unit: $(echo "$out" | grep "^socket $fam:" || echo 'not tried')"; ok=0; }
    done
    [ "$ok" = 1 ] && echo "PASS: as the reader's unit the home and /run/user are read-only, the home reads, socket() of every family ends the process"
    [ "$ok" = 1 ]
}
psvc=org.ruyaos.Profiles1
ppath=/org/ruyaos/Profiles1
# sign_in <profile>: SwitchTo with no PIN, then the dev PIN 1234 when a PIN is asked; prints the reply.
sign_in() {
    local out
    out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$1" "" 2>&1)"
    case "$out" in *'"wrong-pin"'*|*'"pin-required"'*) out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$1" 1234 2>&1)";; esac
    echo "$out"
}
# wait_steam <expected ids, one per line, or ""> <seconds>: until ListItems' Steam ids are exactly those;
# prints the seconds it took.
wait_steam() {
    local n=0
    while [ "$n" -lt "$2" ]; do
        [ "$(list_items | steam_ids)" = "$1" ] && { echo "$n"; return 0; }
        sleep 1; n=$((n + 1))
    done
    return 1
}
steam_manifest() { # <appid> <name> <StateFlags>
    printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"%s"\n\t"LastPlayed"\t\t"1700000000"\n}\n' "$1" "$2" "$3"
}
# What the steam mode made in the profile's home (removed by the exit trap).
steam_made=()
# The second profile the steam mode made, if it made one, and the admin that made it.
steam_profile_made=""
steam_admin=""
steam_clean() {
    [ "${#steam_made[@]}" -gt 0 ] && rm -rf "${steam_made[@]}"
    steam_made=()
    if [ -n "$steam_profile_made" ]; then
        # DeleteProfile refuses the active profile: the admin signs in first.
        sign_in "$steam_admin" >/dev/null
        out="$(busctl --system call "$psvc" "$ppath" "$psvc" DeleteProfile sss "$steam_admin" 1234 "$steam_profile_made" 2>&1)"
        case "$out" in 'suu "ok"'*) ok "DeleteProfile $steam_profile_made: the check's profile is removed";; *) bad "DeleteProfile $steam_profile_made: $out";; esac
        steam_profile_made=""
    fi
}
steam_check() {
    local ids me other user home apps out before t0 s want
    ids="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | tr -d '"')"
    me="$(echo "$ids" | head -1)"; other="$(echo "$ids" | grep -v "^$me\$" | head -1)"
    [ -n "$me" ] || { bad "a profile is needed (vm-goto.ps1 home)"; exit 1; }
    if [ -z "$other" ]; then
        # The VM queue's fresh disk has the one profile vm-goto.ps1 made (admin, PIN 1234): a second
        # one for the switch, removed by the exit trap.
        out="$(busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "$me" 1234 "Check Steam" standard "" 2>&1)"
        case "$out" in 'ssuu "ok" '*) other="$(echo "$out" | cut -d'"' -f4)"; steam_profile_made="$other"; steam_admin="$me";; esac
        [ -n "$other" ] && ok "CreateProfile made $other (Check Steam) for the switch" || { bad "CreateProfile Check Steam: $out"; exit 1; }
    fi
    user="ruya-$me"; home="$(getent passwd "$user" | cut -d: -f6)"
    [ -d "$home" ] || { bad "no home for $user"; exit 1; }
    echo "--- a Steam folder in $me's home: two games, a Proton tool and a linked manifest"
    [ -e "$home/.local/share/Steam" ] && { bad "$home/.local/share/Steam exists already: not touched"; exit 1; }
    apps="$home/.local/share/Steam/steamapps"
    steam_made=("$home/.local/share/Steam" "$home/linked-manifest.acf")
    runuser -u "$user" -- mkdir -p "$apps"
    steam_manifest 70 "Half-Life" 4 | runuser -u "$user" -- tee "$apps/appmanifest_70.acf" >/dev/null
    steam_manifest 220 "Half-Life 2" 4 | runuser -u "$user" -- tee "$apps/appmanifest_220.acf" >/dev/null
    steam_manifest 1493710 "Proton Experimental" 4 | runuser -u "$user" -- tee "$apps/appmanifest_1493710.acf" >/dev/null
    steam_manifest 400 "Portal" 4 | runuser -u "$user" -- tee "$home/linked-manifest.acf" >/dev/null
    runuser -u "$user" -- ln -s "$home/linked-manifest.acf" "$apps/appmanifest_400.acf"
    mkdir -p "$work"
    stdbuf -oL busctl --system --json=short monitor "$svc" > "$work/signals.log" 2>&1 &
    mon=$!
    sleep 2

    echo "--- signed in as $me: exactly the two games"
    out="$(sign_in "$me")"
    case "$out" in 'suu "ok"'*) ok "$me signed in";; *) bad "SwitchTo $me: $out"; exit 1;; esac
    # When $me was in front already the sign-in changed nothing: Rescan asks for its scan (ProfileScanWanted).
    as_shell busctl --system call "$svc" "$path" "$ifc" Rescan >/dev/null
    want="$(printf 'steam:220\nsteam:70')"
    s="$(wait_steam "$want" 40)" && ok "ListItems has steam:70 and steam:220 after about $s s (no Proton tool, no linked manifest)" || bad "the Steam items of $me: $(list_items | steam_ids | tr '\n' ' ')"
    busctl --system get-property "$svc" "$path" "$ifc" ActiveProfile | grep -q "\"$me\"" && ok "ActiveProfile is $me" || bad "ActiveProfile: $(busctl --system get-property "$svc" "$path" "$ifc" ActiveProfile)"
    journalctl -b -u ruya-session --no-pager -o cat | grep -a -E "Steam reader of $me took|Steam items of $me put" | tail -2

    echo "--- switch to $other: ItemsChanged, no Steam item"
    before="$(signals)"
    out="$(sign_in "$other")"
    case "$out" in 'suu "ok"'*) ok "$other signed in";; *) bad "SwitchTo $other: $out";; esac
    s="$(wait_steam "" 30)" && ok "no Steam item for $other after about $s s" || bad "Steam items for $other: $(list_items | steam_ids | tr '\n' ' ')"
    sleep 1
    [ "$(signals)" -gt "$before" ] && ok "ItemsChanged fired on the switch" || bad "no ItemsChanged on the switch"

    echo "--- the root-only members are refused to ruya-shell"
    if out="$(as_shell busctl --system call "$svc" "$path" "$ifc" PutProfileItems ss "$me" '{"version":1,"items":[]}' 2>&1)"; then
        bad "ruya-shell could call PutProfileItems: $out"
    else
        case "$out" in *"ccess denied"*|*AccessDenied*) ok "PutProfileItems from ruya-shell: AccessDenied";; *) bad "PutProfileItems from ruya-shell failed otherwise: $out";; esac
    fi
    if out="$(as_shell busctl --system call "$svc" "$path" "$ifc" SetActiveProfile s "$me" 2>&1)"; then
        bad "ruya-shell could call SetActiveProfile: $out"
    else
        case "$out" in *"ccess denied"*|*AccessDenied*) ok "SetActiveProfile from ruya-shell: AccessDenied";; *) bad "SetActiveProfile from ruya-shell failed otherwise: $out";; esac
    fi

    echo "--- ruya-library reads no home"
    [ "$(systemctl show -p ProtectHome --value ruya-library)" = yes ] && ok "ruya-library has ProtectHome=yes" || bad "ProtectHome: $(systemctl show -p ProtectHome --value ruya-library)"

    echo "--- a restarted ruya-library gets $me's items back without a sign-in"
    out="$(sign_in "$me")"
    wait_steam "$want" 40 >/dev/null || bad "$me's items did not come back on the sign-in"
    t0="$(date +%s)"
    systemctl restart ruya-library
    s="$(wait_steam "$want" 60)" && ok "the two games are back after about $s s, no sign-in" || bad "after the restart: $(list_items | steam_ids | tr '\n' ' ')"
    journalctl -b -u ruya-session --since "@$t0" --no-pager -o cat | grep -a -E "Steam reader|Steam items" | tail -3
    kill "$mon" 2>/dev/null; mon=""

    echo "--- the reader's unit hardening (a unit built like it, in $me's manager)"
    local props=() p uid
    for p in $scan_properties; do props+=("--property=$p"); done
    systemd-run --user --machine="$user@.host" --quiet --unit=ruya-scan-security-check --property=RemainAfterExit=yes "${props[@]}" -- /bin/true \
        && ok "a unit with every reader property starts (none refused by the user manager)" || bad "the user manager refused a reader property (see the journal)"
    uid="$(id -u "$user")"
    runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemd-analyze --user security ruya-scan-security-check.service | tail -3
    systemctl --user --machine="$user@.host" stop ruya-scan-security-check.service >/dev/null 2>&1

    echo "--- the reader's sandbox holds (RUY-1102): as its unit, in $me's manager"
    # The probe goes in on stdin (--pipe): the manager expands $ in a unit's command line.
    printf '%s\n' "$scan_probe" | systemd-run --user --machine="$user@.host" --pipe --wait --quiet --collect --no-ask-password \
        "--property=RuntimeMaxSec=$scan_runtime" "${props[@]}" -- /bin/bash -s 2>&1 | scan_judge || fail=1
}

# --- RUY-137: one game, several installations ------------------------------------------------------
# install_judge linked <a> <b> <preferred> | apart <a> <b>: ListItems (busctl --json=short) on stdin.
# linked: one record holds both installations, under the id <a> (the anchor), confidence "confirmed",
# only <preferred> is marked preferred and the record's launch is its; no other record holds either.
# apart: each is a game of its own (a record with its id and that one installation). Prints PASS or
# FAIL: <why>.
install_judge() {
    python3 -c '
import json, sys
mode, a, b = sys.argv[1:4]
pref = sys.argv[4] if len(sys.argv) > 4 else ""
def val(v):
    return v.get("data") if isinstance(v, dict) and "type" in v and "data" in v else v
try:
    recs = (json.load(sys.stdin).get("data") or [[]])[0]
except ValueError:
    recs = None
def installs(r):
    return [{k: val(x) for k, x in i.items()} for i in (val(r.get("installations")) or [])]
def holding(x):
    return [r for r in recs if any(i.get("id") == x for i in installs(r))]
why = []
if recs is None:
    why.append("no ListItems reply")
elif mode == "linked":
    both = [r for r in recs if {a, b} <= {i.get("id") for i in installs(r)}]
    if len(both) != 1:
        why.append("%d records hold both" % len(both))
    else:
        r = both[0]
        if val(r.get("id")) != a:
            why.append("the game is %s, not %s" % (val(r.get("id")), a))
        if val(r.get("confidence")) != "confirmed":
            why.append("confidence %s" % val(r.get("confidence")))
        chosen = [i.get("id") for i in installs(r) if i.get("preferred")]
        if chosen != [pref]:
            why.append("preferred %s, not %s" % (chosen, pref))
        launch = [i.get("launch") for i in installs(r) if i.get("id") == pref]
        if [val(r.get("launch"))] != launch:
            why.append("launch %s is not the launch of %s" % (val(r.get("launch")), pref))
    if len(holding(a)) != 1 or len(holding(b)) != 1:
        why.append("an installation in more than one record")
elif mode == "apart":
    for x in (a, b):
        h = holding(x)
        if len(h) != 1 or val(h[0].get("id")) != x or len(installs(h[0])) != 1:
            why.append("%s is not a game of its own" % x)
else:
    why.append("unknown mode %s" % mode)
print("FAIL: " + "; ".join(why) if why else "PASS")
' "$@"
}

# installs_are <mode> <a> <b> [preferred] <seconds>: until install_judge passes; prints its last line.
installs_are() {
    local n=0 last secs="${*: -1}" args=("${@:1:$#-1}")
    while :; do
        last="$(list_items_json 2>/dev/null | install_judge "${args[@]}")"
        [ "$last" = PASS ] || [ "$n" -ge "$secs" ] && break
        sleep 1; n=$((n + 1))
    done
    echo "$last"
    [ "$last" = PASS ]
}

install_call() { as_shell busctl --system call "$svc" "$path" "$ifc" "$@" 2>&1; }
installs_linked=""

# installations_check <zip>
installations_check() {
    local me out a b file n=0
    me="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | tr -d '"' | head -1)"
    [ -n "$me" ] || { bad "a profile is needed (vm-goto.ps1 home)"; exit 1; }
    out="$(sign_in "$me")"
    case "$out" in 'suu "ok"'*) ok "$me signed in";; *) bad "SwitchTo $me: $out"; exit 1;; esac
    until busctl --system get-property "$svc" "$path" "$ifc" ActiveProfile | grep -q "\"$me\"" || [ "$n" -ge 30 ]; do sleep 1; n=$((n + 1)); done
    busctl --system get-property "$svc" "$path" "$ifc" ActiveProfile | grep -q "\"$me\"" && ok "ActiveProfile is $me" || { bad "ActiveProfile is not $me"; exit 1; }

    need_clean=1
    build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
    add_remote || exit 1
    install_app "$game" || exit 1
    wait_listed "$game" yes 180 >/dev/null && ok "the test game is listed" || { bad "the test game never appeared"; exit 1; }
    play_install "$1" || exit 1
    a="flatpak:$game"; b="flatpak:play.$play_id"; file="/var/lib/ruyaos/library/$me.json"
    installs_are apart "$a" "$b" 5 >/dev/null && ok "two installations, two games" || bad "before the link: $(list_items_json | install_judge apart "$a" "$b")"

    echo "--- link, prefer, restart"
    out="$(install_call LinkInstallations sss "$me" "$a" "$b")"
    [ "$out" = 's "ok"' ] && { ok "LinkInstallations: ok"; installs_linked="$me $b"; } || bad "LinkInstallations: $out"
    out="$(install_call SetPreferredInstallation sss "$me" "$a" "$a")"
    [ "$out" = 's "ok"' ] && ok "SetPreferredInstallation: ok" || bad "SetPreferredInstallation: $out"
    out="$(installs_are linked "$a" "$b" "$a" 5)" && ok "one game under $a, the Flatpak preferred and launched" || bad "after the link: $out"
    grep -q '"format":2' "$file" 2>/dev/null && grep -q "$b" "$file" && grep -q "\"preferred\":{\"$a\":\"$a\"}" "$file" \
        && ok "the link and the preference are in $file (format 2)" || bad "$file: $(cat "$file" 2>&1)"
    [ "$(stat -c '%U %a' "$file" 2>/dev/null)" = "ruya-library 600" ] && ok "$file is ruya-library's, 0600" || bad "$file: $(stat -c '%U %a' "$file" 2>&1)"
    systemctl restart ruya-library
    out="$(installs_are linked "$a" "$b" "$a" 30)" && ok "the state is back after a restart of ruya-library" || bad "after the restart: $out"
    out="$(install_call SetPreferredInstallation sss "$me" "$a" "flatpak:play.not.installed")"
    [ "$out" = 's "unknown"' ] && ok "an installation that is not installed is unknown" || bad "SetPreferredInstallation of no item: $out"

    echo "--- unlink"
    out="$(install_call UnlinkInstallation ss "$me" "$b")"
    [ "$out" = 's "ok"' ] && { ok "UnlinkInstallation: ok"; installs_linked=""; } || bad "UnlinkInstallation: $out"
    out="$(installs_are apart "$a" "$b" 5)" && ok "two games again" || bad "after the unlink: $out"
    ! grep -q -e "$a" -e "$b" "$file" 2>/dev/null && ok "nothing of them is left in $file" || bad "$file still names them: $(cat "$file")"
    out="$(install_call UnlinkInstallation ss "$me" "$b")"
    [ "$out" = 's "invalid"' ] && ok "a second unlink has nothing to separate: invalid" || bad "the second UnlinkInstallation: $out"
}

clean_all() {
    flatpak uninstall --system -y "$game" "$notes" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work"
    need_clean=0
}

# T-193: whatever way check/seed ends (an early exit 1, Ctrl-C, ssh dropping), stop the signal
# monitor and, when the test repository, remote or apps may exist, remove them. seed keeps its
# apps when it succeeded (that is its purpose) and cleans up when it failed.
mon=""
need_clean=0
keep_on_success=0
play_clean() {
    # Through Play1.Remove (vm-play-check.sh removeapp), so ruya-play forgets the build: a bare flatpak
    # uninstall leaves it recorded and the next install of that build is refused (RUY-1001).
    [ -n "${play_id:-}" ] && { bash "$(dirname "$0")/vm-play-check.sh" removeapp "play.$play_id" || fail=1; }
    [ -n "${play_dev:-}" ] && busctl --system call "$play_svc" "$play_obj" "$play_svc" SetDeveloperMode 'ba{sv}' "$play_dev" 1 admin_approved b true >/dev/null 2>&1
    rm -f "$play_state/incoming/vm-library-check.play.zip"
    play_id=""
}
on_exit() {
    [ -n "$mon" ] && kill "$mon" 2>/dev/null
    # installations stopped between its link and its unlink: the profile keeps no link to the test apps.
    [ -n "${installs_linked:-}" ] && install_call UnlinkInstallation ss ${installs_linked} >/dev/null
    steam_clean
    [ -n "${play_id:-}" ] && play_clean
    if [ "$need_clean" = 1 ] && { [ "$keep_on_success" = 0 ] || [ "$fail" != 0 ]; }; then
        echo "--- clean up (trap)"
        clean_all
    fi
}
trap on_exit EXIT
trap 'fail=1; exit 1' INT TERM HUP

case "${1:-check}" in
play)
    play_check "${2:-/root/hello-play-native.play.zip}"
    play_clean
    ;;
playid)
    play_pkg_id "${2:?app id}"
    ;;
playjudge)
    play_judge "${2:?app id}" "${3:-0}" "${4:-}"
    ;;
runners)
    runners_check "${2:-/root/hello-play-native.play.zip}"
    play_clean
    ;;
runnersjudge)
    runners_judge
    ;;
installations)
    installations_check "${2:-/root/hello-play-native.play.zip}"
    play_clean
    clean_all
    ;;
installjudge)
    out="$(install_judge "${@:2}")"
    [ "$out" = PASS ] && ok "install_judge ${2:-}: the records agree" || bad "install_judge ${2:-}: ${out#FAIL: }"
    ;;
steam)
    steam_check
    steam_clean # here, so a failed removal counts; the exit trap only covers an early stop
    ;;
steamids)
    steam_ids; exit 0 # ids only, no verdict line
    ;;
scanjudge)
    scan_judge || fail=1
    ;;
choicejudge)
    choice_judge "${2:?choice}" && ok "the reply is ok with the choice ${2}" || bad "the reply is not ok with the choice ${2}"
    ;;
security)
    echo "unit hardening: scripts/vm-security-check.sh (one place, with a baseline)"
    ;;
clean)
    clean_all
    ;;
seed)
    need_clean=1; keep_on_success=1
    build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
    add_remote || exit 1
    install_app "$game"; install_app "$notes"
    wait_listed "$game" yes 180 >/dev/null && wait_listed "$notes" yes 60 >/dev/null && ok "both are in the library" || bad "not listed"
    ;;
check)
    echo "--- unit"
    systemctl is-active ruya-library && ok "ruya-library is active" || bad "ruya-library not active"
    systemctl status ruya-library --no-pager | head -8
    uid="$(id -u ruya-library 2>/dev/null)"
    owner="$(busctl --system status "$svc" | sed -n 's/^UID=\([0-9]*\).*/\1/p')"
    echo "the name is owned by uid $owner (ruya-library is $uid)"
    [ -n "$uid" ] && [ "$owner" = "$uid" ] && ok "the service runs as its own user" || bad "owner uid"
    [ "$uid" != 0 ] && ok "not root" || bad "root"

    echo "--- the installed Flatpaks are listed"
    base="$(list_items)"
    echo "$base" | head -c 1200; echo
    # every installed app of the system installation, with the right id
    missing=0
    for id in $(flatpak list --system --app --columns=application); do
        echo "$base" | grep -q "\"flatpak:$id\"" || { echo "missing: $id"; missing=1; }
    done
    [ "$missing" = 0 ] && ok "ListItems has every app of 'flatpak list --system --app'" || bad "ListItems misses installed apps"
    # Steam items are per profile (RUY-1056, the steam mode); a fresh image's profiles have no Steam folder.
    echo "$base" | grep -q '"steam:' && bad "a Steam item without a profile Steam folder" || ok "no Steam items (no profile has a Steam folder yet)"
    echo "$base" | grep -q "$game" && bad "the test game is there before it is installed" || ok "the test game is not installed yet"

    echo "--- build a signed test repository"
    need_clean=1 # from here on the exit trap removes the repository, the remote and the apps
    build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
    add_remote || exit 1
    stdbuf -oL busctl --system --json=short monitor "$svc" > "$work/signals.log" 2>&1 &
    mon=$!
    sleep 2

    echo "--- Install: the app appears, ItemsChanged fires"
    before="$(signals)"
    t0="$(date +%s)"
    install_app "$game" || exit 1
    s="$(wait_listed "$game" yes 180)" && ok "the game is in ListItems after about $s s" || bad "the game never appeared in ListItems"
    t1="$(date +%s)"; echo "install to listed: $((t1 - t0)) s"
    sleep 1
    after="$(signals)"
    [ "$after" -gt "$before" ] && ok "ItemsChanged fired ($before -> $after)" || bad "no ItemsChanged after the install"
    rec="$(record_of "$game")"
    echo "$rec" | head -c 600; echo
    echo "$rec" | grep -q '"kind" s "game"' && ok "kind is game (Categories has Game)" || bad "kind of the test game: $rec"
    # `flatpak list` prints the id's last part ("TestGame") because the test repository has no
    # appstream catalogue; the service takes the name from the exported desktop entry (T-183).
    echo "$rec" | grep -q '"title" s "Test Game"' && ok "title is the desktop entry's Name, not the id's last part" || bad "title: $rec"
    echo "$rec" | grep -q '"source" s "flatpak"' && ok "source is flatpak" || bad "source"
    echo "$rec" | grep -q "\"launch\" s \"flatpak:$game\"" && ok "launch spec" || bad "launch"

    before="$(signals)"
    install_app "$notes" || exit 1
    wait_listed "$notes" yes 120 >/dev/null && ok "the second app is listed" || bad "the second app never appeared"
    rec="$(record_of "$notes")"
    echo "$rec" | grep -q '"kind" s "app"' && ok "kind is app (no Game category)" || bad "kind of the test app: $rec"

    echo "--- Update: a renamed and recategorised app is seen without Rescan (T-183)"
    before="$(signals)"
    commit_before="$(flatpak info --system --show-commit "$game")"
    make_app "$game" "Test Game Reloaded" "Utility;" && ok "a new version was exported" || { bad "cannot build the new version"; exit 1; }
    flatpak build-update-repo $sign "$work/repo" >/dev/null 2>&1 && ok "repository summary updated" || { bad "build-update-repo failed"; exit 1; }
    out="$(flatpak update --system -y --noninteractive "$game" 2>&1)" && ok "flatpak update of the test game" || { echo "$out"; bad "flatpak update failed"; exit 1; }
    echo "$out" | tail -5
    # The check proves nothing unless the installed commit really changed.
    commit_after="$(flatpak info --system --show-commit "$game")"
    echo "commit $commit_before -> $commit_after"
    if echo "$out" | grep -qi "nothing to do" || [ -z "$commit_after" ] || [ "$commit_after" = "$commit_before" ]; then
        bad "flatpak update installed no new commit: the update check cannot run"; exit 1
    fi
    ok "the installed commit changed"
    s="$(wait_record "$game" '"title" s "Test Game Reloaded"' 60)" && ok "the new title is listed after about $s s, no Rescan" || bad "the title did not change: $(record_of "$game")"
    record_of "$game" | grep -q '"kind" s "app"' && ok "the new category made it an app" || bad "kind after the update: $(record_of "$game")"
    sleep 1
    after="$(signals)"
    [ "$after" -gt "$before" ] && ok "ItemsChanged fired for the update ($before -> $after)" || bad "no ItemsChanged after the update"

    echo "--- Uninstall: the app disappears, ItemsChanged fires"
    before="$(signals)"
    out="$(as_shell busctl --system call "$store" "$spath" "$store" Uninstall sb "$game" false)"
    case "$out" in 'ss "ok"'*) ok "Uninstall queued";; *) bad "Uninstall: $out";; esac
    s="$(wait_listed "$game" no 120)" && ok "the game left ListItems after about $s s" || bad "the game is still listed"
    sleep 1
    after="$(signals)"
    [ "$after" -gt "$before" ] && ok "ItemsChanged fired ($before -> $after)" || bad "no ItemsChanged after the uninstall"
    list_items | grep -q "\"flatpak:$notes\"" && ok "the other app is still listed" || bad "the other app vanished"

    echo "--- Rescan and other users"
    before="$(signals)"
    as_shell busctl --system call "$svc" "$path" "$ifc" Rescan >/dev/null && ok "Rescan by ruya-shell" || bad "Rescan failed"
    sleep 1
    [ "$(signals)" = "$before" ] && ok "Rescan of an unchanged library sends nothing" || bad "Rescan sent ItemsChanged for an unchanged list"
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" ListItems 2>&1)"; then
        bad "nobody could call ListItems: $out"
    else
        echo "$out"; ok "ListItems from nobody refused"
    fi
    if out="$(runuser -u ruya-library -- busctl --system call "$svc" "$path" "$ifc" ListItems 2>&1)"; then
        bad "ruya-library could call itself: $out"
    else
        ok "the service account may not call it either"
    fi
    out="$(busctl --system call "$svc" "$path" "$ifc" ListItems 2>&1)" && ok "root may call ListItems" || bad "root refused: $out"
    kill "$mon" 2>/dev/null; mon=""
    journalctl -u ruya-library -b --no-pager | tail -8

    echo "--- clean up"
    clean_all
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
