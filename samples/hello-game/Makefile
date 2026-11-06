# SPDX-License-Identifier: CC0-1.0
# No tab characters in this repository (scripts/lint-text.ps1): recipes start with '>'.
.RECIPEPREFIX = >
PREFIX ?= /app
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra

all: hello-game

hello-game: src/main.c src/game.c src/save.c
>$(CC) $(CFLAGS) $(shell pkg-config --cflags sdl3) -o $@ $^ $(shell pkg-config --libs sdl3) -lm

# The save code needs no SDL: this runs on any Linux with a C compiler.
test: tests/test_game.c src/game.c src/save.c
>$(CC) $(CFLAGS) -o test_game $^ -lm
>./test_game
>rm -f test_game

install: hello-game
>install -Dm755 hello-game $(DESTDIR)$(PREFIX)/bin/hello-game
>install -Dm644 data/org.ruyaos.HelloGame.desktop $(DESTDIR)$(PREFIX)/share/applications/org.ruyaos.HelloGame.desktop
>install -Dm644 data/org.ruyaos.HelloGame.metainfo.xml $(DESTDIR)$(PREFIX)/share/metainfo/org.ruyaos.HelloGame.metainfo.xml
>install -Dm644 data/org.ruyaos.HelloGame.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/org.ruyaos.HelloGame.svg

clean:
>rm -f hello-game test_game

.PHONY: all test install clean
