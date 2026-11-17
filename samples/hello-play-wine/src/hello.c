/* SPDX-License-Identifier: CC0-1.0
 *
 * Hello Play Wine: the smallest Windows game that shows what a .play on Wine looks like.
 * A full screen window, a square that moves with the arrow keys or WASD, a step counter that
 * is saved to Documents\Hello Play\save.txt when the window closes. Under Wine, Documents is a
 * folder inside the prefix; play.json lists it in data.saves as
 * "prefix:drive_c/users/steamuser/Documents/Hello Play", so the console keeps it across a
 * prefix rebuild. Escape quits.
 *
 * Build: ./build.sh (mingw-w64, x86_64-w64-mingw32-gcc).
 */
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>
#include <string.h>

static int g_x = 400, g_y = 300, g_steps;
static char g_save[MAX_PATH + 32];

static void save_path(void)
{
    char docs[MAX_PATH] = ".";
    SHGetFolderPathA(NULL, CSIDL_PERSONAL, NULL, 0, docs);
    char dir[MAX_PATH + 16];
    snprintf(dir, sizeof dir, "%s\\Hello Play", docs);
    CreateDirectoryA(dir, NULL);
    snprintf(g_save, sizeof g_save, "%s\\save.txt", dir);
}

static void load(void)
{
    FILE *f = fopen(g_save, "r");
    if (f) {
        if (fscanf(f, "%d", &g_steps) != 1) {
            g_steps = 0;
        }
        fclose(f);
    }
}

static void save(void)
{
    /* Write a temporary file, then replace the old one: a crash never leaves half a save. */
    char tmp[sizeof g_save + 8];
    snprintf(tmp, sizeof tmp, "%s.tmp", g_save);
    FILE *f = fopen(tmp, "w");
    if (!f) {
        return;
    }
    fprintf(f, "%d\n", g_steps);
    fclose(f);
    MoveFileExA(tmp, g_save, MOVEFILE_REPLACE_EXISTING);
}

static LRESULT CALLBACK proc(HWND w, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_KEYDOWN: {
        int dx = 0, dy = 0;
        switch (wp) {
        case VK_LEFT: case 'A': dx = -24; break;
        case VK_RIGHT: case 'D': dx = 24; break;
        case VK_UP: case 'W': dy = -24; break;
        case VK_DOWN: case 'S': dy = 24; break;
        case VK_ESCAPE: DestroyWindow(w); return 0;
        default: return 0;
        }
        g_x += dx;
        g_y += dy;
        g_steps++;
        InvalidateRect(w, NULL, FALSE);
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(w, &ps);
        RECT all;
        GetClientRect(w, &all);
        HBRUSH bg = CreateSolidBrush(RGB(48, 18, 38));
        FillRect(dc, &all, bg);
        DeleteObject(bg);
        RECT box = { g_x, g_y, g_x + 96, g_y + 96 };
        HBRUSH fg = CreateSolidBrush(RGB(70, 160, 150));
        FillRect(dc, &box, fg);
        DeleteObject(fg);
        char text[64];
        snprintf(text, sizeof text, "Steps: %d (Esc quits)", g_steps);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(240, 240, 240));
        TextOutA(dc, 96, 80, text, (int)strlen(text));
        EndPaint(w, &ps);
        return 0;
    }
    case WM_DESTROY:
        save();
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcA(w, msg, wp, lp);
    }
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    (void)prev;
    (void)cmd;
    save_path();
    load();
    WNDCLASSA wc = { 0 };
    wc.lpfnWndProc = proc;
    wc.hInstance = inst;
    wc.lpszClassName = "HelloPlayWine";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassA(&wc);
    HWND w = CreateWindowA("HelloPlayWine", "Hello Play Wine", WS_POPUP | WS_VISIBLE, 0, 0,
                           GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
                           NULL, NULL, inst, NULL);
    if (!w) {
        return 1;
    }
    ShowWindow(w, show);
    MSG m;
    while (GetMessageA(&m, NULL, 0, 0) > 0) {
        TranslateMessage(&m);
        DispatchMessageA(&m);
    }
    return 0;
}
