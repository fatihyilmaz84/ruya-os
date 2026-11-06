/* SPDX-License-Identifier: CC0-1.0 */
#include "save.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int save_atomic(const char *path, const void *data, size_t len)
{
    char tmp[PATH_MAX], bak[PATH_MAX], dir[PATH_MAX];
    if (snprintf(tmp, sizeof tmp, "%s.tmp-XXXXXX", path) >= (int)sizeof tmp ||
        snprintf(bak, sizeof bak, "%s.bak", path) >= (int)sizeof bak ||
        snprintf(dir, sizeof dir, "%s", path) >= (int)sizeof dir) {
        errno = ENAMETOOLONG;
        return -1;
    }
    char *slash = strrchr(dir, '/');
    if (slash) {
        *slash = '\0';
    } else {
        strcpy(dir, ".");
    }

    /* 1. A temporary file in the same directory (a rename across directories is not atomic). */
    int fd = mkstemp(tmp);
    if (fd < 0)
        return -1;
    const char *p = data;
    size_t left = len;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            int e = errno ? errno : EIO;
            close(fd);
            unlink(tmp);
            errno = e;
            return -1;
        }
        p += n;
        left -= (size_t)n;
    }
    /* 2. Flush the data to disk before it gets its final name. */
    if (fsync(fd) != 0) {
        int e = errno;
        close(fd);
        unlink(tmp);
        errno = e;
        return -1;
    }
    close(fd);

    /* 3. Keep the previous save as .bak, 4. give the new one the final name (atomic). */
    if (access(path, F_OK) == 0 && rename(path, bak) != 0) {
        int e = errno;
        unlink(tmp);
        errno = e;
        return -1;
    }
    if (rename(tmp, path) != 0) {
        int e = errno;
        unlink(tmp);
        errno = e;
        return -1;
    }

    /* 5. Flush the directory entry too. */
    int dfd = open(dir, O_RDONLY | O_DIRECTORY);
    if (dfd >= 0) {
        fsync(dfd);
        close(dfd);
    }
    return 0;
}

char *save_read(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    size_t cap = 4096, used = 0;
    char *buf = malloc(cap);
    while (buf) {
        size_t n = fread(buf + used, 1, cap - used - 1, f);
        used += n;
        if (used < cap - 1)
            break;
        cap *= 2;
        char *bigger = realloc(buf, cap);
        if (!bigger) {
            free(buf);
            buf = NULL;
        } else {
            buf = bigger;
        }
    }
    int failed = ferror(f);
    fclose(f);
    if (!buf)
        return NULL;
    if (failed) {
        free(buf);
        return NULL;
    }
    buf[used] = '\0';
    if (len)
        *len = used;
    return buf;
}

int save_mkdirs(const char *path)
{
    char buf[PATH_MAX];
    if (snprintf(buf, sizeof buf, "%s", path) >= (int)sizeof buf) {
        errno = ENAMETOOLONG;
        return -1;
    }
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/')
            continue;
        *p = '\0';
        if (mkdir(buf, 0700) != 0 && errno != EEXIST)
            return -1;
        *p = '/';
    }
    if (mkdir(buf, 0700) != 0 && errno != EEXIST)
        return -1;
    return 0;
}
