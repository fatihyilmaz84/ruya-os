# SPDX-License-Identifier: CC0-1.0
# No tab characters in this repository (scripts/lint-text.ps1): recipes start with '>'.
.RECIPEPREFIX = >

# The logic of run-windows.py on the host: no Wine, no Proton, no Flatpak.
test:
>python3 -I test_run_windows.py

.PHONY: test
