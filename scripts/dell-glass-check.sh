#!/usr/bin/env bash
# The glass and the GPU load on the Dell (T-421, T-434). Run from Git Bash or WSL on the host:
#   [RUYA_PIN=<digits>] scripts/dell-glass-check.sh [host] [out-dir]
# Needs the key ~/.ssh/ruyaos_dev, the shell running with a profile signed in and Home on screen,
# no app in front and the default look (no wallpaper). It changes no setting. Keys are typed through
# a throw-away uinput keyboard on the Dell (no controller needed); the screen is captured with
# ffmpeg kmsgrab through VA-API, so the captures are what the TV is sent. "Render time" is the
# shell's over 10 s (drm fdinfo, once per client id); 1000 ms in 10 s is 10 % of the GPU.
#   1. Home, 40 s without input. PASS under 3 %: a still Home draws nothing (the blobs rest under
#      the hero's opaque field, the liquid pill's clock rests after 30 s). 0.0.61: about 30 %.
#   2. Home, a key 3 s before (informational): what the liquid pills cost while their clock runs
#      (30 s after each input, LiquidGate). T-421: about 25 %.
#   3. Settings (RB four times): six captures 3 s apart. In the left margin (x 2..88 at 1080p, only
#      L0 is drawn there) the largest luma step between neighbouring pixels. PASS under 6: on a page
#      the backdrop is blurred, so no sharp blob edge crosses it (0.0.61: about 20 when an edge
#      crossed, none when it did not, so only a FAIL proves anything; the captures are kept).
#   4. Settings, a key 2 s before (informational): the blobs drift, the page blur and the pills
#      redraw. T-421: about 40 %.
#   5. Settings, 40 s without input. PASS under 3 %: the blobs rest after 30 s too (LiquidGate).
#   6. The profile picker (Guide, then Accept on "Switch profile"), a key 2 s before
#      (informational: the blobs drift, the page blur's texture is idle off pages, T-434), then
#      40 s without input, PASS under 3 %. Accept signs the focused profile in again; with RUYA_PIN
#      set its digits are typed into the PIN pad. The captures are copied to [out-dir] (default
#      output/dell-glass) for review.
# Not on the High effects tier, or with a wallpaper set, it stops with NOT RUN (exit 2) before step 1.
set -u
HOST="${1:-192.168.178.109}"
OUT="${2:-output/dell-glass}"
SSHO="-i $HOME/.ssh/ruyaos_dev -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
r() { ssh $SSHO "root@$HOST" "$@"; }
mkdir -p "$OUT"
fails=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

r 'mkdir -p /var/tmp/dell-glass && cat > /var/tmp/dell-glass/keys.py' <<'EOF'
import fcntl, os, struct, sys, time
KEYS = {"pgup": 104, "pgdn": 109, "esc": 1, "up": 103, "down": 108, "left": 105, "right": 106,
        "enter": 28, "guide": 172, "0": 11, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8,
        "8": 9, "9": 10}
def emit(fd, t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))
fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, 0x40045564, 1)
for code in KEYS.values():
    fcntl.ioctl(fd, 0x40045565, code)
fcntl.ioctl(fd, 0x405C5503, struct.pack("HHHH80sI", 3, 0x1209, 1, 1, b"dell-glass-keys".ljust(80, b"\0"), 0))
fcntl.ioctl(fd, 0x5501)
try:
    time.sleep(1.5)
    for k in sys.argv[1:]:
        for v in (1, 0):
            emit(fd, 1, KEYS[k], v)
            emit(fd, 0, 0, 0)
            time.sleep(0.1)
        time.sleep(0.4)
    time.sleep(0.3)
finally:
    fcntl.ioctl(fd, 0x5502)
    os.close(fd)
EOF
r 'cat > /var/tmp/dell-glass/step.py' <<'EOF'
import sys
# Largest luma step between horizontal neighbours in x 2..88, y 160..900 (scaled from 1080p) of a PGM.
data = open(sys.argv[1], "rb").read()
parts = data.split(maxsplit=3)
w, h = int(parts[1]), int(parts[2])
px = data[-w * h:]          # P5 with maxval 255: one byte a pixel, the raster ends the file
s = h / 1080.0
best = 0
for y in range(int(160 * s), int(900 * s)):
    row = px[y * w:(y + 1) * w]
    for x in range(int(2 * s), int(88 * s)):
        d = abs(row[x + 1] - row[x])
        if d > best:
            best = d
print(best)
EOF

gpu() {   # render ms of the shell over 10 s, summed once per drm client id
    r 'sp=$(pgrep -x ruya-shell | head -1); declare -A f a
       for d in /proc/$sp/fdinfo/*; do id=$(awk "/drm-client-id/{print \$2}" $d 2>/dev/null); [ -n "$id" ] && [ -z "${f[$id]}" ] && f[$id]=$d && a[$id]=$(awk "/drm-engine-render/{print \$2}" $d); done
       sleep 10; t=0
       for id in "${!f[@]}"; do b=$(awk "/drm-engine-render/{print \$2}" ${f[$id]}); t=$((t + (b - a[$id]) / 1000000)); done
       echo $t'
}
cap() {   # cap <name>: a PNG for review and a grey PGM for the measure
    r "ffmpeg -hide_banner -loglevel error -y -device /dev/dri/card1 -f kmsgrab -i - -vf 'hwmap=derive_device=vaapi,scale_vaapi=format=nv12,hwdownload,format=nv12' -frames:v 1 /var/tmp/dell-glass/$1.png && ffmpeg -hide_banner -loglevel error -y -i /var/tmp/dell-glass/$1.png -vf format=gray -c:v pgm /var/tmp/dell-glass/$1.pgm"
}
keys() { r "python3 /var/tmp/dell-glass/keys.py $*"; }

r 'pgrep -x ruya-shell >/dev/null' || { echo "FAIL: ruya-shell is not running"; exit 1; }
[ -z "$(r 'grep -s "^wallpaper=." /var/lib/ruya-shell/.config/ruyaos/shell.conf')" ] || echo "note: a wallpaper is set; step 2 then measures the picture's blur, not the backdrop's"

still() {   # still <where>: 40 s without input, then PASS under 3 %
    sleep 40
    local ms
    ms=$(gpu)
    echo "$1 after 40 s still: $ms ms render in 10 s"
    [ "$ms" -lt 300 ] && ok "a still $1 draws (almost) nothing ($ms ms in 10 s)" || bad "a still $1 keeps the GPU busy: $ms ms in 10 s"
}

# The precondition "the default look": the High effects tier (the Performance tier draws no blur by
# design, 04 §1.5, so step 3 would FAIL for no product reason; lead-11 found the Dell on it) and no
# wallpaper. The step-3 threshold was tuned on the default theme: the theme is printed.
conf="$(r 'cat /var/lib/ruya-shell/.config/ruyaos/shell.conf 2>/dev/null')"
tier="$(echo "$conf" | sed -n 's/^effectsQuality=//p' | head -1)"
wall="$(echo "$conf" | sed -n 's/^wallpaper=//p' | head -1)"
echo "effects tier: ${tier:-high (default)}; theme: $(echo "$conf" | sed -n 's/^theme=//p' | head -1); wallpaper: ${wall:-none}"
if { [ -n "$tier" ] && [ "$tier" != high ]; } || [ -n "$wall" ]; then
    echo "DELL GLASS CHECK NOT RUN: set Display & motion to the High effects tier and no wallpaper first"
    exit 2
fi

echo "== 1. Home, still"
keys pgup pgup pgup pgup
still Home
cap home

echo "== 2. Home, in use"
keys right left
sleep 3
echo "Home, a key 3 s before: $(gpu) ms render in 10 s (informational: the liquid pills' clock)"

echo "== 3. Settings"
keys pgdn pgdn pgdn pgdn
sleep 2
worst=0
for i in 1 2 3 4 5 6; do
    cap "settings-$i"
    st=$(r "python3 /var/tmp/dell-glass/step.py /var/tmp/dell-glass/settings-$i.pgm")
    echo "settings-$i: largest step in the margin $st"
    [ "$st" -gt "$worst" ] && worst=$st
    sleep 3
done
[ "$worst" -lt 6 ] && ok "no sharp edge in the page's L0 (largest step $worst)" || bad "a sharp edge in the page's L0 (step $worst): the backdrop is not blurred on pages"

echo "== 4. Settings, in use"
keys down up
sleep 2
echo "Settings, a key 2 s before: $(gpu) ms render in 10 s (informational: drift, page blur, pills)"

echo "== 5. Settings, still"
still Settings

echo "== 6. The profile picker"
keys esc esc
sleep 2
keys guide
sleep 1
keys enter
sleep 2
cap picker
keys right left
sleep 2
echo "Picker, a key 2 s before: $(gpu) ms render in 10 s (informational: the blobs drift)"
still "profile picker"
keys enter
pin="${RUYA_PIN:-}"
if [ -n "$pin" ]; then
    sleep 2
    keys $(echo "$pin" | sed 's/./& /g') enter
fi
echo "note: the focused profile was signed in again; check that Home is on screen"
for f in home settings-1 settings-2 settings-3 settings-4 settings-5 settings-6 picker; do
    scp -q $SSHO "root@$HOST:/var/tmp/dell-glass/$f.png" "$OUT/" || true
done
r 'rm -rf /var/tmp/dell-glass'
echo "captures in $OUT"
[ "$fails" -eq 0 ] && echo "DELL GLASS CHECK PASS" || { echo "DELL GLASS CHECK FAIL ($fails)"; exit 1; }
