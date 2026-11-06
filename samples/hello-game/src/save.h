/* SPDX-License-Identifier: CC0-1.0 */
#ifndef HELLO_SAVE_H
#define HELLO_SAVE_H

#include <stddef.h>

/* Writes `data` to `path` so that a power cut at any moment leaves either the old or the new
 * file complete, and keeps the previous file as `path.bak`. Returns 0, or -1 with errno set. */
int save_atomic(const char *path, const void *data, size_t len);

/* Reads a whole file into a new NUL-terminated buffer (free it). NULL if it cannot be read. */
char *save_read(const char *path, size_t *len);

/* Creates `path` and its parents (mode 0700). Returns 0, or -1 with errno set. */
int save_mkdirs(const char *path);

#endif
