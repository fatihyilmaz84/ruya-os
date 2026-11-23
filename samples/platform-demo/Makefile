# SPDX-License-Identifier: CC0-1.0
# No tab characters in this repository (scripts/lint-text.ps1): recipes start with '>'.
.RECIPEPREFIX = >
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra

all: platform-demo

# sd-bus is libsystemd's D-Bus client (the freedesktop runtime has it).
platform-demo: src/platform-demo.c
>$(CC) $(CFLAGS) $(shell pkg-config --cflags libsystemd) -o $@ $^ $(shell pkg-config --libs libsystemd)

# Against the developer mock on a private bus, then with no service at all (tests/run.sh).
test: platform-demo
>sh tests/run.sh

clean:
>rm -f platform-demo

.PHONY: all test clean
