/* SPDX-License-Identifier: CC0-1.0
 *
 * Hello Game: a tiny game that does what the RuyaOS developer guide asks of one.
 *  - full screen, drawn for 1920x1080 and scaled, everything readable inside the safe area;
 *  - a controller (any SDL gamepad, hot-plugged) or the keyboard;
 *  - saves in $XDG_DATA_HOME/saves/, written atomically with a .bak;
 *  - SIGTERM (what the console sends to stop a game) saves and exits within the 5 s grace.
 */
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>

#include "game.h"
#include "save.h"

static volatile sig_atomic_t g_terminate;

static void on_term(int sig)
{
    (void)sig;
    g_terminate = 1; /* only set a flag here; the main loop does the work */
}

static void install_signal_handlers(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
}

/* $XDG_DATA_HOME/saves/slot1.sav; inside Flatpak the variable points into ~/.var/app/<id>/data. */
static void slot_path(char *out, size_t cap)
{
    const char *base = getenv("XDG_DATA_HOME");
    char fallback[512];
    if (!base || !*base) {
        const char *home = getenv("HOME");
        snprintf(fallback, sizeof fallback, "%s/.local/share", home ? home : ".");
        base = fallback;
    }
    char dir[600];
    snprintf(dir, sizeof dir, "%s/saves", base);
    save_mkdirs(dir);
    snprintf(out, cap, "%s/slot1.sav", dir);
}

/* A short "coin" blip: 0.12 s of a falling square wave. Audio is optional; no device, no sound. */
static SDL_AudioStream *g_audio;

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

static void play_blip(void)
{
    if (!g_audio)
        return;
    float wave[5760];
    for (int i = 0; i < 5760; i++) {
        float t = (float)i / 48000.0f;
        float pitch = 880.0f - 3000.0f * t;
        wave[i] = (fmodf(t * pitch, 1.0f) < 0.5f ? 0.15f : -0.15f) * (1.0f - (float)i / 5760.0f);
    }
    SDL_PutAudioStreamData(g_audio, wave, sizeof wave);
}

static uint32_t next_random(void)
{
    static uint32_t s = 2463534242u;
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

static void text(SDL_Renderer *r, float x, float y, const char *fmt, ...) SDL_PRINTF_VARARG_FUNC(4);
static void text(SDL_Renderer *r, float x, float y, const char *fmt, ...)
{
    char line[200];
    va_list ap;
    va_start(ap, fmt);
    SDL_vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    /* The built-in font is 8 px; at scale 3 it is 24 px, the smallest text the guide allows. */
    SDL_SetRenderScale(r, 3.0f, 3.0f);
    SDL_RenderDebugText(r, x / 3.0f, y / 3.0f, line);
    SDL_SetRenderScale(r, 1.0f, 1.0f);
}

static float deadzone(float v)
{
    return fabsf(v) < 0.2f ? 0.0f : v;
}

static void draw(SDL_Renderer *renderer, const GameState *g, int have_pad, int saved_flash)
{
    SDL_SetRenderDrawColor(renderer, 14, 18, 36, 255);
    SDL_RenderClear(renderer);
    SDL_SetRenderDrawColor(renderer, 255, 205, 60, 255);
    SDL_FRect coin = {g->cx, g->cy, 32, 32};
    SDL_RenderFillRect(renderer, &coin);
    SDL_SetRenderDrawColor(renderer, 90, 190, 255, 255);
    SDL_FRect player = {g->px, g->py, 48, 48};
    SDL_RenderFillRect(renderer, &player);
    SDL_SetRenderDrawColor(renderer, 240, 244, 255, 255);
    text(renderer, SAFE_X, SAFE_Y, "Coins %d   Best %d", g->score, g->best);
    text(renderer, SAFE_X, SAFE_Y + 36, have_pad ? "Stick or D-pad: move   A: save now"
                                                 : "Arrows: move   Enter: save now");
    if (saved_flash > 0)
        text(renderer, WORLD_W - SAFE_X - 24 * 5, SAFE_Y, "Saved");
}

static void save_now(const char *slot, const GameState *g, const char *why)
{
    if (game_save(slot, g) == 0)
        printf("hello-game: saved (%s) score=%d best=%d plays=%d played=%us\n", why, g->score,
               g->best, g->plays, g->played_s);
    else
        fprintf(stderr, "hello-game: cannot save to %s: %s\n", slot, strerror(errno));
    fflush(stdout);
}

int main(int argc, char **argv)
{
    int windowed = 0;
    const char *shot = NULL; /* --screenshot FILE.png: draw one frame, write it, exit (store art) */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--windowed") == 0)
            windowed = 1;
        else if (strcmp(argv[i], "--screenshot") == 0 && i + 1 < argc)
            shot = argv[++i];
    }

    install_signal_handlers();
    SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1"); /* we handle SIGTERM ourselves */
    SDL_SetAppMetadata("Hello Game", "1.0.0", "org.ruyaos.HelloGame");

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD | SDL_INIT_AUDIO)) {
        fprintf(stderr, "hello-game: SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window *window = NULL;
    SDL_Renderer *renderer = NULL;
    if (!SDL_CreateWindowAndRenderer("Hello Game", 1920, 1080,
                                     windowed || shot ? SDL_WINDOW_RESIZABLE : SDL_WINDOW_FULLSCREEN,
                                     &window, &renderer)) {
        fprintf(stderr, "hello-game: no window: %s\n", SDL_GetError());
        return 1;
    }
    /* Draw for 1920x1080; SDL scales to 720p, 1080p or 4K and keeps the proportions. */
    SDL_SetRenderLogicalPresentation(renderer, 1920, 1080, SDL_LOGICAL_PRESENTATION_LETTERBOX);
    SDL_SetRenderVSync(renderer, 1);
    SDL_HideCursor();

    if (shot) {
        GameState demo = {.score = 7, .best = 12, .px = 760, .py = 520, .cx = 1180, .cy = 400};
        draw(renderer, &demo, 0, 0);
        SDL_Surface *picture = SDL_RenderReadPixels(renderer, NULL);
        int ok = picture && SDL_SavePNG(picture, shot);
        printf("hello-game: screenshot %s: %s\n", shot, ok ? "written" : SDL_GetError());
        SDL_DestroySurface(picture);
        SDL_Quit();
        return ok ? 0 : 1;
    }
    open_audio();

    char slot[700];
    slot_path(slot, sizeof slot);
    GameState g;
    memset(&g, 0, sizeof g);
    game_new(&g, next_random());
    int from = game_load(slot, &g);
    if (from == 0)
        printf("hello-game: loaded %s (score=%d best=%d plays=%d)\n", slot, g.score, g.best, g.plays);
    else if (from == 1)
        printf("hello-game: %s missing or damaged, loaded the .bak (score=%d)\n", slot, g.score);
    else
        printf("hello-game: no save, new game (%s)\n", slot);
    g.plays++;
    save_now(slot, &g, "start"); /* the save slot exists from the first second */

    SDL_Gamepad *pad = NULL;
    int running = 1;
    Uint64 last = SDL_GetTicks();
    Uint64 second = 0; /* milliseconds of play not yet added to played_s */
    int saved_flash = 0;

    while (running && !g_terminate) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            switch (e.type) {
            case SDL_EVENT_QUIT:
                running = 0;
                break;
            case SDL_EVENT_GAMEPAD_ADDED: /* hot-plug: a pad appears at any time */
                if (!pad) {
                    pad = SDL_OpenGamepad(e.gdevice.which);
                    printf("hello-game: controller connected: %s\n", pad ? SDL_GetGamepadName(pad) : "?");
                }
                break;
            case SDL_EVENT_GAMEPAD_REMOVED:
                if (pad && SDL_GetGamepadID(pad) == e.gdevice.which) {
                    SDL_CloseGamepad(pad);
                    pad = NULL;
                    printf("hello-game: controller removed\n");
                }
                break;
            case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
                if (e.gbutton.button == SDL_GAMEPAD_BUTTON_SOUTH) { /* A / Cross */
                    save_now(slot, &g, "button");
                    saved_flash = 90;
                }
                break;
            case SDL_EVENT_KEY_DOWN:
                /* On the console B also arrives as Esc (the input daemon turns the pad into keys),
                 * and a player leaves through the Guide: Esc quits only in a test window. */
                if (e.key.key == SDLK_ESCAPE && windowed)
                    running = 0;
                if (e.key.key == SDLK_RETURN && !e.key.repeat) {
                    save_now(slot, &g, "key");
                    saved_flash = 90;
                }
                break;
            default:
                break;
            }
        }

        Uint64 now = SDL_GetTicks();
        float dt = (float)(now - last) / 1000.0f;
        last = now;
        if (dt > 0.1f)
            dt = 0.1f; /* a long pause (suspend, a slow frame) must not teleport the player */
        second += (Uint64)(dt * 1000.0f);
        while (second >= 1000) {
            second -= 1000;
            g.played_s++;
        }

        float dx = 0, dy = 0;
        const bool *keys = SDL_GetKeyboardState(NULL);
        if (!pad) { /* with a controller, ignore the keys: today the console also sends the pad as arrow keys */
            if (keys[SDL_SCANCODE_LEFT] || keys[SDL_SCANCODE_A]) dx -= 1;
            if (keys[SDL_SCANCODE_RIGHT] || keys[SDL_SCANCODE_D]) dx += 1;
            if (keys[SDL_SCANCODE_UP] || keys[SDL_SCANCODE_W]) dy -= 1;
            if (keys[SDL_SCANCODE_DOWN] || keys[SDL_SCANCODE_S]) dy += 1;
        } else {
            dx += deadzone((float)SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX) / 32767.0f);
            dy += deadzone((float)SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY) / 32767.0f);
            if (SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_LEFT)) dx -= 1;
            if (SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_RIGHT)) dx += 1;
            if (SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_UP)) dy -= 1;
            if (SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_DOWN)) dy += 1;
        }
        if (dx > 1) dx = 1;
        if (dx < -1) dx = -1;
        if (dy > 1) dy = 1;
        if (dy < -1) dy = -1;

        if (game_step(&g, dx, dy, dt, next_random())) {
            play_blip();
            save_now(slot, &g, "coin");
        }

        draw(renderer, &g, pad != NULL, saved_flash);
        if (saved_flash > 0)
            saved_flash--;
        SDL_RenderPresent(renderer);
        SDL_Delay(2); /* never spin, even where vsync does nothing (no display) */
    }

    /* Quit event or SIGTERM: this is the moment to save. The console waits 5 seconds. */
    printf("hello-game: %s, saving\n", g_terminate ? "SIGTERM" : "quit");
    save_now(slot, &g, g_terminate ? "sigterm" : "quit");
    if (pad)
        SDL_CloseGamepad(pad);
    if (g_audio)
        SDL_DestroyAudioStream(g_audio);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
