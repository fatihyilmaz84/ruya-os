#!/usr/bin/env bash
# The in-kernel Xbox 360 wireless receiver support is in the built image (RUY-154): `xpad` is a
# module (or built in) and its module aliases cover the receiver's USB ids 045e:0719 and
# 045e:0291, so the kernel loads it by itself when the receiver is plugged in. No out-of-tree
# controller driver (xone, xpadneo) and no firmware for it is in the image.
#   scripts/check-image-input-drivers.sh [image]      (in WSL, repo root; default localhost/ruyaos:dev)
# Exit 1 lists what is missing. The shell and service side is tested by dev.ps1 test; the
# receiver with a real pad is a hardware check on the Dell (hw pending).
set -euo pipefail
cd "$(dirname "$0")/.."
image="${1:-localhost/ruyaos:dev}"

inner="$(mktemp)"
trap 'rm -f "$inner"' EXIT
cat > "$inner" <<'INNER'
fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok() { echo "ok:   $*"; }
kver="$(ls /usr/lib/modules | sort -V | tail -n1)"
dir="/usr/lib/modules/$kver"
if grep -qE '(^|/)xpad\.ko' "$dir/modules.builtin" 2>/dev/null; then
    ok "xpad is built into the kernel $kver"
else
    ko="$(find "$dir" -name 'xpad.ko*' | head -n1)"
    [ -n "$ko" ] && ok "xpad module present: ${ko#"$dir"/}" || bad "no xpad module under $dir"
    # modules.alias is what udev reads to load the module for a USB device. The driver matches
    # the receiver either by its product id or by Microsoft's vendor id with the Xbox 360 wireless
    # interface (class ff, subclass 5d, protocol 81): accept both forms, and say which one matched.
    for id in 0719 0291; do
        hit="$(grep -E "^alias usb:v045Ep(${id}|\*)d.* xpad$" "$dir/modules.alias" \
            | grep -E "p${id}d|isc5Dip(81|\*)" | head -n1 || true)"
        [ -n "$hit" ] && ok "modules.alias loads xpad for 045e:${id}: ${hit}" \
            || bad "modules.alias has no xpad entry that covers 045e:${id}"
    done
fi
for name in xone xpadneo xow; do
    find "$dir" -name "${name}*.ko*" | grep -q . && bad "out-of-tree driver $name is in the image" || ok "no $name module"
done
if ls /usr/lib/firmware 2>/dev/null | grep -qiE 'xone|xbox|gip'; then
    bad "controller firmware found in /usr/lib/firmware"
else
    ok "no Xbox adapter firmware"
fi
exit $fail
INNER
podman run --rm -v "$inner:/check.sh:ro" "$image" bash /check.sh
