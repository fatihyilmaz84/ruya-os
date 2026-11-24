#pragma once

#include <QColor>
#include <QHash>
#include <QImage>
#include <QObject>
#include <QQmlEngine>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariantMap>
#include <QVector>

// The colours of a card's picture (T-281, 04 §3.8): one or two representative colours per picture,
// worked out once when the picture is first asked for, off the GUI thread, and cached by source.
// The card's glow (a Hue-style shadow in the colours of its art) reads them; nothing here runs per
// frame.
//
// The sampler shrinks the picture to at most 32 x 32 pixels, buckets the pixels by hue weighted by
// saturation squared times value (so dark and washed-out pixels count for little), takes the
// strongest hue (smoothed over its two neighbours) as the primary colour and the strongest hue at
// least 90 degrees away as the secondary one (the primary again when there is none worth showing).
// Both are then conditioned: lightness in [MinLightness, MaxLightness] and saturation in
// [MinSaturation, MaxSaturation], so a pale pastel and a neon picture give glows of the same weight.
// A picture without a dominant hue (white, grey, black) gives a neutral grey. `strength` (0.2 to 1)
// is how loudly the glow should speak: a very dark picture gives a faint one, a neutral one is
// capped at NeutralStrengthMax.
//
// The same pass keeps the light of the sample (RUY-1117, 04 §5.5): the WCAG relative luminance (linearised sRGB,
// transparent pixels over black) of each of the sample's pixels, `lumWidth` x `lumHeight`, row by row. The top bar's
// ink (RUY-1136) reads the top band of what is on screen from it (`band`): the picture is drawn as a centred
// PreserveAspectCrop, so the band is the top BandShare of the rows the crop for the view's aspect leaves visible, and
// each item of the bar reads the part of it under its own x range.
struct ArtColors
{
    bool ok = false;
    QColor primary;
    QColor secondary;
    qreal strength = 0;
    bool neutral = false;
    QVector<float> lum;     // lumWidth x lumHeight, row by row
    int lumWidth = 0;
    int lumHeight = 0;
};

// The light of a band of a picture: the BandQuantile (`high`) and 1 - BandQuantile (`low`) relative luminance.
struct ArtBand
{
    qreal high = 0;
    qreal low = 0;
};

class ArtPalette : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // How many pictures have been decoded and analysed (a picture asked for twice counts once), and
    // the time the last analysis took in microseconds (decoding excluded): tests and the Outcome
    // use them to show the sampler runs once per picture and costs next to nothing.
    Q_PROPERTY(int analysed READ analysed NOTIFY sampled)
    Q_PROPERTY(qint64 lastAnalyseUs READ lastAnalyseUs NOTIFY sampled)

public:
    static constexpr qreal MinLightness = 0.40;
    static constexpr qreal MaxLightness = 0.60;
    static constexpr qreal MinSaturation = 0.35;
    static constexpr qreal MaxSaturation = 0.90;
    static constexpr qreal MinStrength = 0.20;
    static constexpr qreal NeutralStrengthMax = 0.60;
    static constexpr int SampleSize = 32;
    static constexpr qreal BandShare = 0.20;        // the top band: this share of the rows (at least one)
    // A band's `high` is this quantile of its luminances, its `low` 1 - this: a bright patch behind the clock or
    // the nav counts, a few stray pixels do not.
    static constexpr qreal BandQuantile = 0.98;
    // A column the item's x range touches by more than this share of the view's width (one glyph of the clock, about
    // 19 px at 1080p) is under it too: an item over a patch's edge is busy as a whole (RUY-1159).
    static constexpr qreal GlyphShare = 0.01;
    static constexpr int CacheLimit = 256;          // pictures remembered; the cache starts over beyond this
    static constexpr qint64 MaxDownloadBytes = 8LL * 1024 * 1024;
    static constexpr int DownloadTimeoutMs = 15000;   // a download that stalls this long is a failure

    explicit ArtPalette(QQmlEngine *engine = nullptr, QObject *parent = nullptr);
    ~ArtPalette() override;

    static ArtPalette *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    // The pure part, used by the worker and the tests: the colours of an image.
    static ArtColors analyse(const QImage &image);
    // The pure part of bandOf: the top band of `colors`' sample as drawn into a view of `viewAspect` (width / height)
    // with a centred PreserveAspectCrop (0 or less: the whole picture is shown, no crop), under the view's x range
    // `from`..`to` (fractions of its width, RUY-1136): the sample columns whose centres lie in it and any it touches by
    // more than GlyphShare (RUY-1159), at least the one under its middle (a column is about 60 px of a 1080p screen: one
    // touched by less is mostly the neighbour's art).
    static ArtBand band(const ArtColors &colors, qreal viewAspect, qreal from = 0, qreal to = 1);

    int analysed() const { return m_analysed; }
    qint64 lastAnalyseUs() const { return m_lastUs; }

    // The colours of the picture at `source` (a path, file:, qrc: or http(s) URL, as AppArt's
    // `picture`): { color, secondary, strength, neutral } once known, else an empty map, and the
    // picture is loaded and analysed in the background; `sampled(source)` follows. A picture that
    // cannot be read stays empty for good (the card keeps its placeholder colour) and emits nothing.
    Q_INVOKABLE QVariantMap colorsOf(const QString &source);

    // The light of the top band of the picture as drawn into a view of `viewAspect` (RUY-1117, see `band`), under the
    // view's x range `from`..`to` (fractions of its width; the whole width by default, RUY-1136):
    // { ok: true, high, low } (relative luminances 0..1) once known, else an empty map, loaded and analysed like
    // colorsOf (the same decode, the same cache, the same `sampled(source)`). An unreadable picture stays empty.
    Q_INVOKABLE QVariantMap bandOf(const QString &source, qreal viewAspect, qreal from = 0, qreal to = 1);

    // The worker's result, on the GUI thread (called by the worker's queued hand-over; not for callers).
    static void deliver(ArtPalette *self, const QString &source, const ArtColors &colors, qint64 us)
    {
        self->finish(source, colors, us);
    }

signals:
    // The colours of `source` are known (a later colorsOf returns them).
    void sampled(const QString &source);

private:
    // The known result for `source`, or nullptr while it is unknown (and then its analysis is started).
    const ArtColors *lookup(const QString &source);
    void finish(const QString &source, const ArtColors &colors, qint64 us);
    void startFile(const QString &source);
    void startDownload(const QString &source);

    QQmlEngine *m_engine = nullptr;
    QHash<QString, ArtColors> m_done;     // ok == false: unreadable
    QSet<QString> m_pending;
    int m_analysed = 0;
    qint64 m_lastUs = 0;
};
