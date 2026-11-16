#!/usr/bin/env bash
# Sourced by build.sh and test-vm-checks.sh (RUY-771).
# ruya_stage_names <Containerfile>: the names of the named build stages ("FROM x AS name"), one per
# line. A FROM without AS (the final image) has no name and is not listed.
ruya_stage_names() {
    sed -nE 's/^FROM[[:space:]].*[[:space:]][Aa][Ss][[:space:]]+([A-Za-z0-9_.-]+)[[:space:]]*$/\1/p' "$1"
}
