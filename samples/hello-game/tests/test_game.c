/* SPDX-License-Identifier: CC0-1.0
 * Tests for the save code, no SDL needed: `make test`. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../src/game.h"
#include "../src/save.h"

static void write_file(const char *path, const char *text)
{
    FILE *f = fopen(path, "wb");
    assert(f);
    fputs(text, f);
    fclose(f);
}

int main(void)
{
    char dir[] = "/tmp/hello-game-test-XXXXXX";
    assert(mkdtemp(dir));
    char slot[300], bak[310];
    snprintf(slot, sizeof slot, "%s/slot1.sav", dir);
    snprintf(bak, sizeof bak, "%s.bak", slot);

    /* A round trip keeps every field. */
    GameState a = {.score = 3, .best = 9, .plays = 2, .played_s = 41, .px = 100.5f, .py = 200.5f, .cx = 300.5f, .cy = 400.5f};
    char text[512];
    assert(game_serialise(&a, text, sizeof text) > 0);
    GameState b;
    memset(&b, 0, sizeof b);
    assert(game_parse(text, &b) == 0);
    assert(b.score == 3 && b.best == 9 && b.plays == 2 && b.played_s == 41);

    /* One flipped digit fails the CRC. */
    char damaged[512];
    strcpy(damaged, text);
    damaged[strstr(damaged, "score=3") - damaged + 6] = '4';
    assert(game_parse(damaged, &b) == -1);

    /* No save at all: a new game. */
    GameState g;
    memset(&g, 0, sizeof g);
    assert(game_load(slot, &g) == 2);

    /* First save: no .bak yet. Second save: the first one becomes the .bak. */
    assert(game_save(slot, &a) == 0);
    assert(access(bak, F_OK) != 0);
    a.score = 4;
    assert(game_save(slot, &a) == 0);
    assert(access(bak, F_OK) == 0);
    assert(game_load(slot, &g) == 0 && g.score == 4);

    /* The newest save is torn (a power cut mid-write on a file system without atomic rename
     * would look like this): the load falls back to the .bak, which holds the one before. */
    write_file(slot, "hello-game 1\nscore=9");
    assert(game_load(slot, &g) == 1 && g.score == 3);

    /* No temporary files are left behind. */
    char cmd[400];
    snprintf(cmd, sizeof cmd, "test -z \"$(ls %s | grep tmp-)\"", dir);
    assert(system(cmd) == 0);

    snprintf(cmd, sizeof cmd, "rm -rf %s", dir);
    assert(system(cmd) == 0);
    puts("hello-game tests: ok");
    return 0;
}
