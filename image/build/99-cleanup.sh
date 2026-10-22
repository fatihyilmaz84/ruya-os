#!/usr/bin/env bash
set -euo pipefail
dnf clean all
rm -rf /var/cache/* /var/log/* /var/lib/dnf /tmp/* /var/tmp/*
