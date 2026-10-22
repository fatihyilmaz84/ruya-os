#!/usr/bin/env bash
# bootc only populates /var on first install; later image updates never touch it. Every
# directory packages left in /var therefore needs a tmpfiles.d entry so it is (re)created on
# systems installed from an older image. Generate entries for anything not already covered.
# (Satisfies the `var-tmpfiles` check of `bootc container lint`.)
set -euo pipefail

out=/usr/lib/tmpfiles.d/ruyaos-image-var.conf
known="$(systemd-tmpfiles --cat-config 2>/dev/null | awk '$1 ~ /^[dDvqQLCzZ]$/ { print $2 }' | sort -u)"

: > "$out"
find /var -mindepth 1 -type d \
    -not -path '/var/cache*' -not -path '/var/log*' -not -path '/var/tmp*' \
    -not -path '/var/lib/dnf*' -not -path '/var/lib/rpm*' -print0 |
while IFS= read -r -d '' dir; do
    if ! grep -qxF "$dir" <<<"$known"; then
        stat -c 'd %n %a %U %G - -' "$dir" >> "$out"
    fi
done
echo "95-var-tmpfiles: $(wc -l < "$out") entries in $out"
