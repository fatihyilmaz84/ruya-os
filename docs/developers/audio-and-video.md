# Audio and video

How sound gets from your game to the speakers, what the console does with the output, which codecs you can count on, and what is not there yet (HDR, VRR). **The path that carries a profile game's sound to the speakers is planned (B-007): today a game started by the console has no audio route.** Write your audio normally and it will work when the route lands.

*Checked against the code as of 2026-11-06. Items marked **planned** are not built yet.*

## The rules

1. **Play sound through PulseAudio's protocol**: ask for `--socket=pulseaudio` and use SDL audio, OpenAL, FMOD, Wwise, Qt Multimedia or any engine's default Linux backend. The console runs PipeWire and offers the pulse protocol to apps (ADR-010); PipeWire's own API is not offered to profile apps.
2. **Always use the default output device.** Do not offer an output picker and do not open a specific device. The player chooses the output in the console's Settings, and it follows what they plug in; your stream moves with it.
3. **Do not build a master volume.** The controller's volume buttons and the volume overlay belong to the console and change the system volume. Give the player music and effects sliders if you like.
4. **Survive having no audio device**: it can be missing (no HDMI sound, a headset that just disconnected). Do not exit; play silence. The sample does this (`open_audio`).
5. **Label your stream**: set the *game* role (`media.role=game`; SDL: `SDL_HINT_AUDIO_DEVICE_STREAM_ROLE` set to `game`), so the console's sound policy can tell your game's stream from a video player's. The console's sound policy (ducking, spec 02 section 5) is designed around stream roles; how much of it is built for app streams is not verified.
6. **Expect silence while the player is in Ruya Hub.** Your game is frozen there, so your stream is not fed and plays nothing; the console also parks the stream on a silent null sink while you are frozen (so the sound card can go idle) and moves it back where it was on the thaw (T-466; not yet heard on hardware). Your stream stays open and you see nothing of it. A stream that has had no sound for 5 s, frozen or not, is paused by the sound server and resumes at your next write, so after a long freeze you are asked for a few seconds of sound, not the whole pause (RUY-425). While a game is parked, a null sink `ruya-parked` can appear in the sink list: do not enumerate, select or rely on it; its name and existence are not an API. Do not move your stream by hand. Nothing to do in your code, except that music or video that follows a clock should re-sync after the pause (what the player hears at the thaw has not been checked on hardware yet) ([Full screen and lifecycle](fullscreen-and-lifecycle.md)).
7. **Keep latency sensible.** Buffers of about 20 ms or less for effects; do not rely on exact figures yet, they have not been measured on the console.

## Example: SDL 3

A short sound effect, with no failure when there is no device (from `samples/hello-game/src/main.c`):

```c
/* sample: samples/hello-game/src/main.c */
static void open_audio(void)
{
    SDL_SetHint(SDL_HINT_AUDIO_DEVICE_STREAM_ROLE, "game"); /* the console can tell a game from a video */
    SDL_AudioSpec spec = {SDL_AUDIO_F32, 1, 48000};
    g_audio = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, NULL, NULL);
    if (g_audio)
        SDL_ResumeAudioStreamDevice(g_audio);
    else
        fprintf(stderr, "hello-game: no audio output (%s)\n", SDL_GetError());
}
```

`SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK` is "the default output", which is what you want; SDL moves the stream when the default changes.

## How the sound reaches the speakers

- **One PipeWire for the whole console**, run by the shell's own session (ADR-010). Profile users do not run their own against the hardware; the console switches that off for them.
- **Per-profile audio socket: planned (B-007).** `ruya-session` is meant to expose the shell's PulseAudio-compatible socket in the profile's runtime directory, limited to the active profile; Flatpak's `--socket=pulseaudio` then finds it. It is not built, so a game started by `Session1.Launch` has no sound today. It also means the first release of this route will only offer the **pulse protocol**: do not expect the PipeWire socket.
- **The output follows WirePlumber's choice**: HDMI, analog, USB or Bluetooth, preferring the device that was connected most recently, with a toast when it changes (spec 02 section 5, spec 03 section 2.3). Audio output switching while a game plays (a Bluetooth headset connects) must be handled by your audio library: nothing for you to do but not crash.
- **Volume**: the master volume and mute are the console's (`org.ruyaos.Devices1`, the volume keys). The console also has UI sound effects and an ambient loop; the ambient loop is muted whenever an app is in front (spec 02 section 5).
- **Not built yet:** applying the console's "media" level to app streams (B-007), per-app volume.

## Codecs: what you can rely on

- **The image** carries the full codec set (RPM Fusion ffmpeg, GStreamer freeworld, VA-API drivers; ADR-009). **A Flatpak does not see the host's codecs**: it gets what its runtime and the runtime's extensions have.
- With the freedesktop runtime, Flatpak installs the extension `org.freedesktop.Platform.codecs-extra` together with the runtime (it did in our test of `org.freedesktop.Platform//26.08`); `org.freedesktop.Platform.ffmpeg-full` is the larger FFmpeg build. The spec says the console's store installs them on first boot (spec 03 section 6); **that is not built**, so on a console without network and without them, only what your runtime ships is there.
- **Safe choice for game video and audio:** formats that need no patent licence and ship in the runtime or in your own app: **VP9 or AV1 video, Opus or Vorbis audio, WebM or Ogg containers**, or your engine's own decoder (Bink, Theora, ...). H.264, HEVC and AAC work only where the runtime's codec extension is present.

## Hardware video decode and output

- **Decode:** on the host, VA-API drivers for Intel, AMD and NVIDIA are in the image. Whether your Flatpak reaches them depends on the runtime's GL and VA-API extensions; the spec's check is running `vainfo` inside the sandbox on real hardware. **Not verified.** Do not assume hardware decode; fall back to software decode.
- **Output size:** the display's mode; 720p, 1080p and 4K are the design targets. See [Full screen and lifecycle](fullscreen-and-lifecycle.md).
- **HDR and VRR (variable refresh) are not supported** and out of the first release's scope (spec 00, scope list). Render in SDR (sRGB).
- **GL on the real display:** the shell logs on real Intel hardware that its compositor lacks `EGL_WL_bind_wayland_display`; T-164 has to choose a buffer-sharing route (`linux-dmabuf`) and test a GL client. **A GPU-rendered game window has not been shown on the console yet.**

## Checklist

- [ ] `--socket=pulseaudio` is in the manifest, nothing else for sound.
- [ ] Sound plays on the default device and keeps playing when the default changes.
- [ ] The game starts and runs with no audio device.
- [ ] Your stream has the *game* role.
- [ ] No master-volume slider of your own; music and effects sliders are fine.
- [ ] Video uses VP9 or AV1, or software decoding is acceptable if H.264 is missing.
- [ ] No HDR or VRR assumptions.

## Sources

Checked on 2026-11-06 against: `docs/specs/00-overview.md` ADR-009, ADR-010 and the scope list; `docs/specs/02-shell.md` section 5; `docs/specs/03-services-and-apps.md` sections 2.3, 6; `docs/STATUS.md` (B-007; the 2026-11-06 Inbox line on `EGL_WL_bind_wayland_display`); `docs/tasks/T-164-per-profile-wayland-sockets.md`; `image/build/30-codecs.sh` and `20-base.sh` (PipeWire, pulse, codecs on the host); `services/ruya-store` (no codec-extension installer exists: `grep codecs-extra` finds nothing); the output of `flatpak install` of `org.freedesktop.Platform//26.08` (the codecs-extra extension is installed with it); `samples/hello-game/src/main.c` (audio, tried with SDL's dummy audio driver only).
