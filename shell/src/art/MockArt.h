#pragma once

#include <QString>

// Tests only (T-281): the picture the mock library and store give their i-th item when a test asks
// for pictures ("art:<dir>" scenario, Store.mockArtDir): <dir>/<colour>.png, cycling through the
// fixtures tst_main.cpp writes. They show the glow on red, blue, green, white and dark art and on
// a two-colour picture.
inline QString mockArtPath(const QString &dir, int index)
{
    static const char *const names[] = {"red", "blue", "green", "white", "dark", "redblue"};
    return dir + QLatin1Char('/') + QLatin1String(names[index % 6]) + QStringLiteral(".png");
}
