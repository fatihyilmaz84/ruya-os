#!/usr/bin/env bash
# Q4: limits of a running play.* app's units, what a package-chosen environment
# variable can break, and 32-bit Windows programs under Flathub Wine's WoW64.
# Needs q1-hello.sh and q2-wine.sh build first. Runs as root; the Wine checks run
# as the profile (prun) so the prefix belongs to the player.
. "$(dirname "$0")/common.sh"
set +e +o pipefail   # every check reports, none stops the run
P=${PROFILE:-p1}; U=ruya-$P
call() { busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 "$@"; }

echo "== limits of a Session1-launched app (play.test.hello sleeps 60 s)"
call Launch ss play.test.hello "$P"; sleep 3
for unit in $(systemctl --user -M "$U@.host" list-units --plain --no-legend \
        'app-flatpak-play.test.hello-*' "ruya-app-$U-play.test.hello.service" | cut -d' ' -f1); do
    echo "-- $unit"
    systemctl --user -M "$U@.host" show "$unit" -p Slice,MemoryMax,MemoryHigh,MemorySwapMax,TasksMax,CPUQuotaPerSecUSec,CPUWeight,IOWeight,OOMPolicy,ManagedOOMMemoryPressure
done
echo "-- user-$(id -u "$U").slice: $(systemctl show "user-$(id -u "$U").slice" -p MemoryMax -p TasksMax | tr '\n' ' ')"
call Stop s "ruya-app-$U-play.test.hello.service" >/dev/null

echo "== package-chosen environment (flatpak run --env, as a manifest's run.env would do)"
echo "-- LD_PRELOAD reaches the sandboxed process:"
prun "$P" flatpak run --env=LD_PRELOAD=/app/payload/evil.so --command=sh play.test.hello \
    -c 'echo "LD_PRELOAD=$LD_PRELOAD"; true' 2>&1 | head -3
echo "-- VK_ICD_FILENAMES pointing nowhere hides the GPU from Vulkan (DXVK/VKD3D):"
# No vulkaninfo in the runtime or SDK: count physical devices through the loader.
VKCOUNT='import ctypes as c
vk = c.CDLL("libvulkan.so.1")
ci = (c.c_uint32 * 16)(); ci[0] = 1          # VkInstanceCreateInfo, sType 1, rest zero
inst = c.c_void_p(); r = vk.vkCreateInstance(c.byref(ci), None, c.byref(inst))
n = c.c_uint32(0)
if r == 0: vk.vkEnumeratePhysicalDevices(inst, c.byref(n), None)
print("vkCreateInstance", r, "physical devices", n.value)'
for v in "" "--env=VK_ICD_FILENAMES=/nonexistent.json"; do
    echo "   [${v:-default}] $(flatpak run --device=dri $v --command=python3 play.test.hello -c "$VKCOUNT" 2>&1 | tail -1)"
done
echo "-- WINEPREFIX from the package replaces the platform's per-profile prefix:"
prun "$P" flatpak run --env=WINEPREFIX=/app/prefix --env=WINEDEBUG=-all --command=wineboot play.test.winex11 -i 2>&1 | head -2
prun "$P" flatpak run --env=WINEPREFIX=/tmp/prefix --env=WINEDEBUG=-all --command=sh play.test.winex11 \
    -c 'wineboot -i; ls -d /tmp/prefix/drive_c && echo "(a prefix in the sandbox tmpfs: gone with the instance, saves lost)"' 2>&1 | tail -1

echo "== 32-bit Windows program (syswow64\\cmd.exe) under Flathub Wine 11 (old WoW64: i386-unix)"
for m in "" "--disallow=multiarch"; do
    echo "-- [${m:-allow=multiarch}]"
    prun "$P" flatpak run $m --env=WINEPREFIX=/var/data/prefix --env=WINEDEBUG=-all --command=wine \
        play.test.winex11 'C:\windows\syswow64\cmd.exe' /c 'echo 32-bit cmd ok' 2>&1 | tr -d '\r' | tail -2
done
