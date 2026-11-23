#pragma once

#include <QRgb>

#include <algorithm>
#include <cmath>
#include <vector>

// WCAG relative luminance (linearised sRGB), shared by the pictures' light measures: the wallpaper's
// floor and peak (Wallpapers) and the top band of art behind the status tray (ArtPalette, RUY-1117).
// The QML side has the same arithmetic in ThemeMath (`channel`, `luminance`, `grey`).
namespace Luminance {

inline double toLinear(double s)   // an sRGB channel 0..1
{
    return s <= 0.04045 ? s / 12.92 : std::pow((s + 0.055) / 1.055, 2.4);
}

inline double toSrgb(double l)
{
    return l <= 0.0031308 ? l * 12.92 : 1.055 * std::pow(l, 1.0 / 2.4) - 0.055;
}

inline double of(double r, double g, double b)   // sRGB channels 0..1
{
    return 0.2126 * toLinear(r) + 0.7152 * toLinear(g) + 0.0722 * toLinear(b);
}

inline double of(QRgb c)
{
    return of(qRed(c) / 255.0, qGreen(c) / 255.0, qBlue(c) / 255.0);
}

// The q-quantile (0..1, nearest rank) of values already sorted ascending; 0 for none.
inline double quantile(const std::vector<double> &sorted, double q)
{
    if (sorted.empty())
        return 0.0;
    return sorted[std::min(sorted.size() - 1, size_t(std::floor(q * (sorted.size() - 1) + 0.5)))];
}

} // namespace Luminance
