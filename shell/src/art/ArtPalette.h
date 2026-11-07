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
struct ArtColors
{
    bool ok = false;
    QColor primary;
    QColor secondary;
    qreal strength = 0;
    bool neutral = false;
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
    static constexpr int CacheLimit = 256;          // pictures remembered; the cache starts over beyond this
    static constexpr qint64 MaxDownloadBytes = 8LL * 1024 * 1024;

    explicit ArtPalette(QQmlEngine *engine = nullptr, QObject *parent = nullptr);
    ~ArtPalette() override;

    static ArtPalette *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    // The pure part, used by the worker and the tests: the colours of an image.
    static ArtColors analyse(const QImage &image);

    int analysed() const { return m_analysed; }
    qint64 lastAnalyseUs() const { return m_lastUs; }

    // The colours of the picture at `source` (a path, file:, qrc: or http(s) URL, as AppArt's
    // `picture`): { color, secondary, strength, neutral } once known, else an empty map, and the
    // picture is loaded and analysed in the background; `sampled(source)` follows. A picture that
    // cannot be read stays empty for good (the card keeps its placeholder colour) and emits nothing.
    Q_INVOKABLE QVariantMap colorsOf(const QString &source);

signals:
    // The colours of `source` are known (a later colorsOf returns them).
    void sampled(const QString &source);

private:
    void finish(const QString &source, const ArtColors &colors, qint64 us);
    void startFile(const QString &source);
    void startDownload(const QString &source);

    QQmlEngine *m_engine = nullptr;
    QHash<QString, ArtColors> m_done;     // ok == false: unreadable
    QSet<QString> m_pending;
    int m_analysed = 0;
    qint64 m_lastUs = 0;
};
