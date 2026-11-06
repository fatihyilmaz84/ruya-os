/* SPDX-License-Identifier: CC0-1.0 */
#ifndef HELLO_GAME_H
#define HELLO_GAME_H

#include <stddef.h>
#include <stdint.h>

/* The world is 1920 x 1080; the window scales it to the real screen. */
#define WORLD_W 1920.0f
#define WORLD_H 1080.0f
/* 5 % of the screen is kept free at every edge (overscan, docs/specs/04 section 2). */
#define SAFE_X 96.0f
#define SAFE_Y 54.0f

typedef struct {
    int score;           /* coins collected in this game */
    int best;            /* best score ever */
    int plays;           /* how many times the game was started */
    unsigned played_s;   /* seconds played in total */
    float px, py;        /* the player */
    float cx, cy;        /* the coin */
} GameState;

/* A new game; `rnd` places the first coin. Keeps best/plays/played_s of `g` untouched. */
void game_new(GameState *g, uint32_t rnd);

/* Moves the player by (dx, dy) in -1..1 units per second. Returns 1 if a coin was collected. */
int game_step(GameState *g, float dx, float dy, float dt, uint32_t rnd);

/* The save file's text, with a CRC-32 of everything before the last line. Returns its length. */
size_t game_serialise(const GameState *g, char *out, size_t cap);

/* Parses that text. Returns 0, or -1 if it is damaged, from another version, or its CRC fails. */
int game_parse(const char *text, GameState *g);

/* Loads `path`, else `path.bak`. Returns 0 (path), 1 (the .bak) or 2 (neither: `g` is unchanged). */
int game_load(const char *path, GameState *g);

/* Saves atomically (save_atomic). Returns 0, or -1 with errno set. */
int game_save(const char *path, const GameState *g);

uint32_t crc32_of(const void *data, size_t len);

#endif
