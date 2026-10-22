#!/bin/sh
# Failing this on 3 consecutive boots makes greenboot roll back to the previous image.
exec /usr/libexec/ruyaos/wait-shell-ready 90
