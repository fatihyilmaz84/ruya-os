/* SPDX-License-Identifier: CC0-1.0 */
#include "game.h"

#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "save.h"

#define SPEED 700.0f      /* pixels per second */
#define PLAYER_SIZE 48.0f
#define COIN_SIZE 32.0f

uint32_t crc32_of(const void *data, size_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    const unsigned char *p = data;
    for (size_t i = 0; i < len; i++) {
        crc ^= p[i];
        for (int k = 0; k < 8; k++)
            crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

static void place_coin(GameState *g, uint32_t rnd)
{
    float span_x = WORLD_W - 2 * SAFE_X - COIN_SIZE;
    float span_y = WORLD_H - 2 * SAFE_Y - COIN_SIZE - 120.0f; /* room for the score line */
    g->cx = SAFE_X + (float)(rnd & 0xFFFF) / 65535.0f * span_x;
    g->cy = SAFE_Y + 120.0f + (float)((rnd >> 16) & 0xFFFF) / 65535.0f * span_y;
}

void game_new(GameState *g, uint32_t rnd)
{
    g->score = 0;
    g->px = WORLD_W / 2;
    g->py = WORLD_H / 2;
    place_coin(g, rnd);
}

int game_step(GameState *g, float dx, float dy, float dt, uint32_t rnd)
{
    g->px += dx * SPEED * dt;
    g->py += dy * SPEED * dt;
    if (g->px < SAFE_X) g->px = SAFE_X;
    if (g->px > WORLD_W - SAFE_X - PLAYER_SIZE) g->px = WORLD_W - SAFE_X - PLAYER_SIZE;
    if (g->py < SAFE_Y + 120.0f) g->py = SAFE_Y + 120.0f;
    if (g->py > WORLD_H - SAFE_Y - PLAYER_SIZE) g->py = WORLD_H - SAFE_Y - PLAYER_SIZE;

    float ox = (g->px + PLAYER_SIZE / 2) - (g->cx + COIN_SIZE / 2);
    float oy = (g->py + PLAYER_SIZE / 2) - (g->cy + COIN_SIZE / 2);
    if (fabsf(ox) < (PLAYER_SIZE + COIN_SIZE) / 2 && fabsf(oy) < (PLAYER_SIZE + COIN_SIZE) / 2) {
        g->score++;
        if (g->score > g->best)
            g->best = g->score;
        place_coin(g, rnd);
        return 1;
    }
    return 0;
}

/* One line per value, the CRC of all lines before it on the last line. */
size_t game_serialise(const GameState *g, char *out, size_t cap)
{
    int n = snprintf(out, cap,
                     "hello-game 1\n"
                     "score=%d\nbest=%d\nplays=%d\nplayed=%u\n"
                     "px=%.1f\npy=%.1f\ncx=%.1f\ncy=%.1f\n",
                     g->score, g->best, g->plays, g->played_s, g->px, g->py, g->cx, g->cy);
    if (n < 0 || (size_t)n >= cap)
        return 0;
    int m = snprintf(out + n, cap - (size_t)n, "crc=%08x\n", (unsigned)crc32_of(out, (size_t)n));
    if (m < 0 || (size_t)(n + m) >= cap)
        return 0;
    return (size_t)(n + m);
}

int game_parse(const char *text, GameState *g)
{
    const char *crc_line = strstr(text, "crc=");
    if (!crc_line || strncmp(text, "hello-game 1\n", 13) != 0)
        return -1;
    unsigned want = 0;
    if (sscanf(crc_line, "crc=%8x", &want) != 1 || want != crc32_of(text, (size_t)(crc_line - text)))
        return -1;
    GameState t = *g;
    int got = sscanf(text,
                     "hello-game 1\nscore=%d\nbest=%d\nplays=%d\nplayed=%u\n"
                     "px=%f\npy=%f\ncx=%f\ncy=%f\n",
                     &t.score, &t.best, &t.plays, &t.played_s, &t.px, &t.py, &t.cx, &t.cy);
    if (got != 8 || t.score < 0 || t.best < t.score)
        return -1;
    *g = t;
    return 0;
}

static int load_one(const char *path, GameState *g)
{
    char *text = save_read(path, NULL);
    if (!text)
        return -1;
    int rc = game_parse(text, g);
    free(text);
    return rc;
}

int game_load(const char *path, GameState *g)
{
    if (load_one(path, g) == 0)
        return 0;
    char bak[PATH_MAX];
    snprintf(bak, sizeof bak, "%s.bak", path);
    if (load_one(bak, g) == 0)
        return 1;
    return 2;
}

int game_save(const char *path, const GameState *g)
{
    char buf[512];
    size_t n = game_serialise(g, buf, sizeof buf);
    if (n == 0)
        return -1;
    return save_atomic(path, buf, n);
}
