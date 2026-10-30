#!/bin/sh
# An image whose update service does not start cannot be updated or rolled back by the user:
# failing this on 3 consecutive boots makes greenboot roll back to the previous image.
timeout=60
elapsed=0
while [ "$elapsed" -lt "$timeout" ]; do
    if systemctl is-active --quiet ruya-update.service; then
        exit 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done
echo "ruya-update.service is not active after ${timeout}s" >&2
exit 1
