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
 *   - it reads a settings file next to its own program (check.ini, which the package ships) and
 *     writes a file there (beside.txt, its own launch count), as games such as Unreal Tournament
 *     keep their ini and saves in their install folder: the package lists that folder in
 *     run.writable (RUY-1019), so the console gives each profile a copy it may write;
 *   - it tries to reach the internet and reports whether it could (the sample asks for no network).
 * It writes the report to Documents\Hello Play\check.txt (key=value lines) and prints it: launches,
 * pointer_bits, wow64, network, module (the path GetModuleFileNameW gives, as UTF-8), edition (the
 * number in check.ini, 0 without one) and beside (the count it wrote to beside.txt, or "failed").
 * Exit 0 when the report was written, 1 when it could not be.
 *
 * Build: ./build.sh (mingw-w64, i686-w64-mingw32-gcc).
 */
#include <winsock2.h>
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

/* The number after "<key>=" in the key=value lines of f (closed here), 0 when there is none or
 * f is NULL (the file is not there). */
static int number_in(FILE *f, const char *key)
{
    int n = 0;
    char line[128];
    size_t len = strlen(key);
    if (!f) {
        return 0;
    }
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, key, len) == 0 && line[len] == '='
            && sscanf(line + len + 1, "%d", &n) == 1) {
            break;
        }
    }
    fclose(f);
    return n > 0 ? n : 0;
}

/* Write text to path through a temporary file, then replace the old one: a crash never leaves
 * half a file. 1 when it was written. */
static int replace_file(const wchar_t *path, const char *text)
{
    wchar_t tmp[MAX_PATH + 24];
    if (wcslen(path) + 5 > sizeof tmp / sizeof tmp[0]) {
        return 0;
    }
    wcscpy(tmp, path);
    wcscat(tmp, L".tmp");
    FILE *f = _wfopen(tmp, L"w");
    if (!f) {
        return 0;
    }
    size_t len = strlen(text);
    size_t wrote = fwrite(text, 1, len, f);
    if (fclose(f) != 0 || wrote != len) {
        return 0;
    }
    return MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING) ? 1 : 0;
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
    /* This program's own path and folder, the way a Windows game finds its install folder. */
    wchar_t module[MAX_PATH], ini[MAX_PATH + 16], beside[MAX_PATH + 16];
    char module_utf8[4 * MAX_PATH];
    DWORD got = GetModuleFileNameW(NULL, module, MAX_PATH);
    wchar_t *slash = got > 0 && got < MAX_PATH ? wcsrchr(module, L'\\') : NULL;
    if (!slash
        || !WideCharToMultiByte(CP_UTF8, 0, module, -1, module_utf8, (int)sizeof module_utf8,
                                NULL, NULL)) {
        fprintf(stderr, "check: no path for this program\n");
        return 1;
    }
    size_t folder = (size_t)(slash - module) + 1;
    wmemcpy(ini, module, folder);
    ini[folder] = L'\0';
    wcscpy(beside, ini);
    wcscat(ini, L"check.ini");
    wcscat(beside, L"beside.txt");

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

    int launches = number_in(fopen(path, "r"), "launches") + 1;
    int edition = number_in(_wfopen(ini, L"r"), "edition");
    /* Next to the program, its own count: a relaunch and an update show the file stayed. */
    int here = number_in(_wfopen(beside, L"r"), "launches") + 1;
    char line[32], beside_text[16];
    snprintf(line, sizeof line, "launches=%d\n", here);
    if (replace_file(beside, line)) {
        snprintf(beside_text, sizeof beside_text, "%d", here);
    } else {
        snprintf(beside_text, sizeof beside_text, "failed");
    }
    BOOL wow64 = FALSE;
    IsWow64Process(GetCurrentProcess(), &wow64);
    char report[256 + sizeof module_utf8];
    int len = snprintf(report, sizeof report,
                       "launches=%d\npointer_bits=%d\nwow64=%d\nnetwork=%s\nmodule=%s\n"
                       "edition=%d\nbeside=%s\n",
                       launches, (int)(8 * sizeof(void *)), wow64 ? 1 : 0,
                       network_open() ? "open" : "closed", module_utf8, edition, beside_text);

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
