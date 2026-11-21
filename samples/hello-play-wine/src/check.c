/* SPDX-License-Identifier: CC0-1.0
 *
 * check.exe: the sample's command-line program for the console's VM check (RUY-902,
 * scripts/vm-play-check.sh launch-windows). A headless machine cannot press the arrow keys of
 * hello.exe, so the check runs this instead: a 32-bit console program that exits by itself.
 *
 * It does what a Windows game does that the check wants to see on a real console:
 *   - it is 32-bit, so it runs only when the sandbox allows 32-bit code (permissions.multiarch);
 *   - it keeps a save in Documents\Hello Play, which play.json lists in data.saves, and counts its
 *     launches in it, so a second launch shows the save survived;
 *   - it tries to reach the internet and reports whether it could (the sample asks for no network).
 * It writes the report to Documents\Hello Play\check.txt (key=value lines) and prints it. Exit 0
 * when the report was written, 1 when it could not be.
 *
 * Build: ./build.sh (mingw-w64, i686-w64-mingw32-gcc).
 */
#include <winsock2.h>
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>
#include <string.h>

/* The number after "launches=" in the report of the last launch, 0 when there is none. */
static int previous_launches(const char *path)
{
    int n = 0;
    char line[128];
    FILE *f = fopen(path, "r");
    if (!f) {
        return 0;
    }
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "launches=%d", &n) == 1) {
            break;
        }
    }
    fclose(f);
    return n > 0 ? n : 0;
}

/* 1 when a TCP connection to a public address is made within three seconds, else 0. */
static int network_open(void)
{
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        return 0;
    }
    int open = 0;
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s != INVALID_SOCKET) {
        u_long nonblocking = 1;
        ioctlsocket(s, FIONBIO, &nonblocking);
        struct sockaddr_in to;
        memset(&to, 0, sizeof to);
        to.sin_family = AF_INET;
        to.sin_port = htons(53);
        to.sin_addr.s_addr = inet_addr("1.1.1.1");
        if (connect(s, (struct sockaddr *)&to, sizeof to) == 0) {
            open = 1;
        } else if (WSAGetLastError() == WSAEWOULDBLOCK) {
            fd_set writable, failed;
            FD_ZERO(&writable);
            FD_ZERO(&failed);
            FD_SET(s, &writable);
            FD_SET(s, &failed);
            struct timeval wait = { 3, 0 };
            open = select(0, NULL, &writable, &failed, &wait) > 0 && FD_ISSET(s, &writable);
        }
        closesocket(s);
    }
    WSACleanup();
    return open;
}

int main(void)
{
    char docs[MAX_PATH];
    if (SHGetFolderPathA(NULL, CSIDL_PERSONAL, NULL, 0, docs) != S_OK) {
        fprintf(stderr, "check: no Documents folder\n");
        return 1;
    }
    char dir[MAX_PATH + 16], path[MAX_PATH + 32], tmp[MAX_PATH + 40];
    snprintf(dir, sizeof dir, "%s\\Hello Play", docs);
    CreateDirectoryA(dir, NULL);
    snprintf(path, sizeof path, "%s\\check.txt", dir);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);

    int launches = previous_launches(path) + 1;
    BOOL wow64 = FALSE;
    IsWow64Process(GetCurrentProcess(), &wow64);
    char report[256];
    int len = snprintf(report, sizeof report,
                       "launches=%d\npointer_bits=%d\nwow64=%d\nnetwork=%s\n", launches,
                       (int)(8 * sizeof(void *)), wow64 ? 1 : 0,
                       network_open() ? "open" : "closed");

    /* Write a temporary file, then replace the old one: a crash never leaves half a save. */
    FILE *f = fopen(tmp, "w");
    if (!f) {
        fprintf(stderr, "check: cannot write %s\n", tmp);
        return 1;
    }
    size_t wrote = fwrite(report, 1, (size_t)len, f);
    if (fclose(f) != 0 || wrote != (size_t)len
        || !MoveFileExA(tmp, path, MOVEFILE_REPLACE_EXISTING)) {
        fprintf(stderr, "check: cannot save %s\n", path);
        return 1;
    }
    fputs(report, stdout);
    return 0;
}
