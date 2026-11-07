# Boot experience lint (T-269): the files that make the boot silent, branded and menu-less are
# all in the repository and agree with each other. This is a static check of the sources; the
# built image is checked by scripts/check-boot-config.sh and the boot itself by the VM (dev-setup.md,
# "Boot experience").
#   - kargs.d keeps the silent-boot arguments (and not the old loglevel=3);
#   - the Plymouth theme "ruyaos": .plymouth file, script, every image the script loads;
#   - the GRUB policy for new disks (bootupd static config) and for old ones (custom.cfg + its sync);
#   - the compositor starts after Plymouth has quit, before the shutdown splash, and plymouth-quit retains the splash;
#   - the image build installs the script plugin, selects the theme and does not slim it away.
#
# Used by dev.ps1 (test) and by the CI workflow. Windows PowerShell 5.1 and pwsh. Exit code 0 = clean.
#   .\scripts\lint-boot.ps1 [-Root <repository root>]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$findings = New-Object System.Collections.Generic.List[string]
function Fail([string]$msg) { $findings.Add($msg) }
function Text([string]$rel) {
    $p = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $p)) { Fail "missing: $rel"; return "" }
    return [IO.File]::ReadAllText($p)
}

# 1. Kernel arguments.
$kargs = Text "image/rootfs/usr/lib/bootc/kargs.d/10-ruyaos.toml"
$required = @("quiet", "splash", "loglevel=0", "vt.global_cursor_default=0", "systemd.show_status=false",
    "rd.systemd.show_status=false", "rd.udev.log_level=0", "udev.log_level=0", "rd.plymouth=1",
    "plymouth.enable=1", "plymouth.ignore-serial-consoles")
$line = ($kargs -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join " "
foreach ($a in $required) {
    if ($line -notmatch ('"' + [regex]::Escape($a) + '"')) { Fail "kargs.d/10-ruyaos.toml: missing argument $a" }
}
if ($line -match '"loglevel=[1-9]') { Fail "kargs.d/10-ruyaos.toml: loglevel above 0 prints kernel messages on the console" }

# 2. The Plymouth theme.
$themeDir = "image/rootfs/usr/share/plymouth/themes/ruyaos"
$plymouth = Text "$themeDir/ruyaos.plymouth"
if ($plymouth -notmatch '(?m)^ModuleName=script\s*$') { Fail "$themeDir/ruyaos.plymouth: ModuleName must be script" }
if ($plymouth -notmatch '(?m)^ImageDir=/usr/share/plymouth/themes/ruyaos\s*$') { Fail "$themeDir/ruyaos.plymouth: ImageDir must be /usr/share/plymouth/themes/ruyaos" }
if ($plymouth -notmatch '(?m)^ScriptFile=/usr/share/plymouth/themes/ruyaos/ruyaos\.script\s*$') { Fail "$themeDir/ruyaos.plymouth: ScriptFile must be /usr/share/plymouth/themes/ruyaos/ruyaos.script" }
$script = Text "$themeDir/ruyaos.script"
$images = [regex]::Matches($script, 'Image\("([^"]+)"\)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
if (-not $images) { Fail "$themeDir/ruyaos.script loads no image" }
foreach ($img in $images) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root "$themeDir/$img"))) { Fail "$themeDir/ruyaos.script loads $img, which is not in the theme" }
}
if ($script -match 'Image\.Text|Plymouth\.SetMessageFunction|Plymouth\.SetDisplayMessageFunction') { Fail "$themeDir/ruyaos.script draws text; the splash shows none" }

# 3. GRUB: no menu on a normal boot, menu after a failed one.
$static = Text "image/rootfs/usr/lib/bootupd/grub2-static/configs.d/07_ruyaos-menu.cfg"
foreach ($pat in @('(?m)^set ruya_menu_policy=1\s*$', '(?m)^set timeout_style=hidden\s*$', '(?m)^set timeout=[0-9]\s*$',
        '(?m)^if \[ "\$\{boot_success\}" = "0" -o -n "\$\{boot_counter\}" \]; then\s*$', '(?m)^\s+set timeout_style=menu\s*$')) {
    if ($static -notmatch $pat) { Fail "07_ruyaos-menu.cfg: expected a line matching $pat" }
}
$custom = Text "image/rootfs/usr/lib/ruyaos/grub-menu-custom.cfg"
# Rollback must stay reachable: every timeout is at least 1 s ("set timeout=0" boots at once, with no window for Esc).
foreach ($cfg in @(@{ Name = "07_ruyaos-menu.cfg"; Text = $static }, @{ Name = "grub-menu-custom.cfg"; Text = $custom })) {
    $timeouts = [regex]::Matches($cfg.Text, '(?m)^\s*set timeout=(\S*)') | ForEach-Object { $_.Groups[1].Value }
    if (@($timeouts).Count -lt 2) { Fail "$($cfg.Name): expected a hidden and a menu timeout" }
    foreach ($t in $timeouts) { if ($t -notmatch '^[1-9][0-9]*$') { Fail "$($cfg.Name): 'set timeout=$t' leaves no window for Esc (rollback unreachable); use at least 1" } }
}
$marker = "# ruyaos-managed: grub-menu-custom.cfg"
if (($custom -split "`n")[0].TrimEnd() -ne $marker) { Fail "grub-menu-custom.cfg: the first line must be '$marker' (the sync only overwrites files that carry it)" }
if ($custom -notmatch '(?m)^if \[ -z "\$\{ruya_menu_policy\}" \]; then\s*$') { Fail "grub-menu-custom.cfg: must be guarded by ruya_menu_policy (new disks already have the policy in grub.cfg)" }
if ($custom -notmatch '(?m)^\s+set timeout_style=hidden\s*$') { Fail "grub-menu-custom.cfg: must hide the menu" }
if ($custom -notmatch '(?m)^  if \[ -n "\$\{boot_counter\}" \]; then\s*$') { Fail "grub-menu-custom.cfg: must show the menu while boot_counter is set (a failed boot)" }
$sync = Text "image/rootfs/usr/libexec/ruyaos/grub-menu-sync"
if ($sync -notmatch [regex]::Escape("marker='$marker'")) { Fail "grub-menu-sync: marker differs from grub-menu-custom.cfg" }
$unit = Text "image/rootfs/usr/lib/systemd/system/ruya-grub-menu.service"
if ($unit -notmatch 'ExecStart=/usr/libexec/ruyaos/grub-menu-sync') { Fail "ruya-grub-menu.service does not run grub-menu-sync" }

# 4. Splash and shell: Plymouth is gone before the shell starts, and back for the shutdown splash.
$comp = Text "image/rootfs/usr/lib/systemd/system/ruya-compositor@.service"
if ($comp -notmatch '(?m)^After=.*plymouth-quit-wait\.service') { Fail "ruya-compositor@.service: must start after plymouth-quit-wait (eglfs only gets the display, DRM master, when Plymouth has exited)" }
if ($comp -match '(?m)^ExecStartPre=.*plymouth deactivate') { Fail "ruya-compositor@.service: 'plymouth deactivate' does not release the display for an unprivileged compositor (T-269); do not use it" }
if ($comp -notmatch '(?m)^Before=.*plymouth-reboot\.service.*') { Fail "ruya-compositor@.service: must be ordered before plymouth-reboot/poweroff (the shutdown splash)" }
$quit = Text "image/rootfs/usr/lib/systemd/system/plymouth-quit.service.d/10-ruyaos.conf"
if ($quit -notmatch '(?m)^ExecStart=-/usr/bin/plymouth quit --retain-splash\s*$') { Fail "plymouth-quit.service.d/10-ruyaos.conf: must quit with --retain-splash" }

# 5. Image build.
if ((Text "image/build/20-base.sh") -notmatch 'plymouth-plugin-script') { Fail "20-base.sh: plymouth-plugin-script (the script module the theme needs) is not installed" }
if ((Text "image/build/90-initramfs.sh") -notmatch 'plymouth-set-default-theme ruyaos') { Fail "90-initramfs.sh: the default theme must be ruyaos" }
if ((Text "image/build/50-slim.sh") -match 'plymouth-plugin-script') { Fail "50-slim.sh: must not remove plymouth-plugin-script" }
if ((Text "image/Containerfile") -notmatch 'systemctl enable [^\r\n]*ruya-grub-menu\.service') { Fail "Containerfile: ruya-grub-menu.service is not enabled" }
if ((Text "image/build/enabled-units.txt") -notmatch '(?m)^ruya-grub-menu\.service\s') { Fail "enabled-units.txt: ruya-grub-menu.service has no line" }

if ($findings.Count -gt 0) {
    Write-Host "boot lint: $($findings.Count) finding(s)"
    $findings | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "boot lint: ok"
exit 0
