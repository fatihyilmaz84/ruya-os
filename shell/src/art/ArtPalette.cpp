#include "ArtPalette.h"

#include <QBuffer>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QImageReader>
#include <QMetaObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QThreadPool>
#include <QUrl>

#include <algorithm>
#include <array>
#include <cmath>

namespace {

constexpr int HueBuckets = 12;
constexpr qreal ChromaticMean = 0.015;   // mean pixel weight below this: no dominant hue
constexpr qreal SecondaryShare = 0.30;   // the secondary needs this share of the primary's score

int distance(int a, int b)
{
    const int d = std::abs(a - b);
    return std::min(d, HueBuckets - d);
}

struct Bucket
{
    qreal w = 0, r = 0, g = 0, b = 0;
};

// The colour of buckets i-1..i+1 (weighted mean).
QColor meanOf(const std::array<Bucket, HueBuckets> &buckets, int i)
{
    qreal w = 0, r = 0, g = 0, b = 0;
    for (int k = -1; k <= 1; ++k) {
        const Bucket &x = buckets[(i + k + HueBuckets) % HueBuckets];
        w += x.w;
        r += x.r;
        g += x.g;
        b += x.b;
    }
    if (w <= 0)
        return QColor::fromRgbF(0.5, 0.5, 0.5);
    return QColor::fromRgbF(r / w, g / w, b / w);
}

// Lightness and saturation into the glow's band.
QColor condition(const QColor &c)
{
    float h, s, l;
    c.getHslF(&h, &s, &l);
    if (h < 0)
        h = 0;
    return QColor::fromHslF(h, std::clamp(qreal(s), ArtPalette::MinSaturation, ArtPalette::MaxSaturation),
                            std::clamp(qreal(l), ArtPalette::MinLightness, ArtPalette::MaxLightness));
}

qreal smooth(qreal x, qreal lo, qreal hi)
{
    const qreal t = std::clamp((x - lo) / (hi - lo), 0.0, 1.0);
    return t * t * (3 - 2 * t);
}

bool isRemote(const QString &source)
{
    return source.startsWith(QLatin1String("http://")) || source.startsWith(QLatin1String("https://"));
}

// The file to read for a local source: a path, file:// or qrc:/ (":/..").
QString localPath(const QString &source)
{
    if (source.startsWith(QLatin1String("qrc:")))
        return QLatin1Char(':') + QUrl(source).path();
    if (source.startsWith(QLatin1String("file:")))
        return QUrl(source).toLocalFile();
    return source;
}

// A picture from a file or from downloaded bytes: refused above 100 megapixels, decoded at a reduced
// size (JPEG decodes small natively) since the sampler looks at 32 x 32 pixels anyway.
QImage decode(QImageReader &reader)
{
    reader.setAutoTransform(true);
    const QSize size = reader.size();
    if (size.isValid() && qint64(size.width()) * size.height() > 100LL * 1000 * 1000)
        return {};
    const int limit = 4 * ArtPalette::SampleSize;
    if (size.isValid() && (size.width() > limit || size.height() > limit))
        reader.setScaledSize(size.scaled(limit, limit, Qt::KeepAspectRatio));
    return reader.read();
}

QImage decodeFile(const QString &path)
{
    QImageReader reader(path);
    return decode(reader);
}

QImage decodeBytes(const QByteArray &bytes)
{
    QByteArray copy = bytes;
    QBuffer buffer(&copy);
    buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer);
    return decode(reader);
}

// From a worker thread: hand the result to the GUI thread through the application object (not through
// `self`, which may be gone while the worker runs), and look at the QPointer only there.
void post(const QPointer<ArtPalette> &self, const QString &source, const ArtColors &colors, qint64 us)
{
    if (!qApp)
        return;
    QMetaObject::invokeMethod(qApp, [self, source, colors, us] {
        if (self)
            ArtPalette::deliver(self.data(), source, colors, us);
    }, Qt::QueuedConnection);
}

} // namespace

ArtColors ArtPalette::analyse(const QImage &image)
{
    ArtColors out;
    if (image.isNull() || image.width() < 1 || image.height() < 1)
        return out;

    QImage small = image.width() > SampleSize || image.height() > SampleSize
        ? image.scaled(SampleSize, SampleSize, Qt::KeepAspectRatio, Qt::SmoothTransformation)
        : image;
    // Over black: a transparent pixel is no colour.
    small = small.convertToFormat(QImage::Format_ARGB32_Premultiplied).convertToFormat(QImage::Format_RGB32);

    std::array<Bucket, HueBuckets> buckets{};
    qreal meanV = 0, meanW = 0;
    qreal sumR = 0, sumG = 0, sumB = 0;
    const int count = small.width() * small.height();
    for (int y = 0; y < small.height(); ++y) {
        const QRgb *line = reinterpret_cast<const QRgb *>(small.constScanLine(y));
        for (int x = 0; x < small.width(); ++x) {
            const QColor c = QColor::fromRgb(line[x]);
            float h, s, v;
            c.getHsvF(&h, &s, &v);
            meanV += v;
            sumR += c.redF();
            sumG += c.greenF();
            sumB += c.blueF();
            if (h < 0)
                continue;                            // achromatic: no hue
            const qreal w = s * s * v;
            meanW += w;
            Bucket &bucket = buckets[std::min(HueBuckets - 1, int(h * HueBuckets))];
            bucket.w += w;
            bucket.r += w * c.redF();
            bucket.g += w * c.greenF();
            bucket.b += w * c.blueF();
        }
    }
    meanV /= count;
    meanW /= count;

    out.ok = true;
    if (meanW < ChromaticMean) {
        // No dominant hue: a neutral grey, never louder than NeutralStrengthMax.
        const QColor mean = QColor::fromRgbF(sumR / count, sumG / count, sumB / count);
        const qreal l = std::clamp(qreal(mean.lightnessF()), MinLightness, MaxLightness);
        out.primary = out.secondary = QColor::fromHslF(0, 0, l);
        out.neutral = true;
        out.strength = std::min(NeutralStrengthMax, MinStrength + (1 - MinStrength) * smooth(meanV, 0.05, 0.6));
        return out;
    }

    auto score = [&](int i) {
        return buckets[i].w + 0.5 * (buckets[(i + 1) % HueBuckets].w + buckets[(i + HueBuckets - 1) % HueBuckets].w);
    };
    int best = 0;
    for (int i = 1; i < HueBuckets; ++i) {
        if (score(i) > score(best))
            best = i;
    }
    int second = -1;
    for (int i = 0; i < HueBuckets; ++i) {
        if (distance(i, best) < 3)
            continue;
        if (second < 0 || score(i) > score(second))
            second = i;
    }
    out.primary = condition(meanOf(buckets, best));
    out.secondary = second >= 0 && score(second) >= SecondaryShare * score(best) ? condition(meanOf(buckets, second))
                                                                                 : out.primary;
    // Brightness and how much of the picture is colour set the volume.
    const qreal bright = smooth(meanV, 0.05, 0.5);
    const qreal chroma = std::clamp(0.5 + meanW * 4, 0.5, 1.0);
    out.strength = std::clamp((MinStrength + (1 - MinStrength) * bright) * chroma, MinStrength, 1.0);
    return out;
}

ArtPalette::ArtPalette(QQmlEngine *engine, QObject *parent)
    : QObject(parent)
    , m_engine(engine)
{
}

ArtPalette::~ArtPalette() = default;

ArtPalette *ArtPalette::create(QQmlEngine *qmlEngine, QJSEngine *)
{
    return new ArtPalette(qmlEngine);
}

QVariantMap ArtPalette::colorsOf(const QString &source)
{
    if (source.isEmpty())
        return {};
    const auto it = m_done.constFind(source);
    if (it != m_done.constEnd()) {
        if (!it->ok)
            return {};
        return {{QStringLiteral("color"), it->primary},
                {QStringLiteral("secondary"), it->secondary},
                {QStringLiteral("strength"), it->strength},
                {QStringLiteral("neutral"), it->neutral}};
    }
    if (!m_pending.contains(source)) {
        m_pending.insert(source);
        if (isRemote(source))
            startDownload(source);
        else
            startFile(source);
    }
    return {};
}

void ArtPalette::finish(const QString &source, const ArtColors &colors, qint64 us)
{
    m_pending.remove(source);
    if (m_done.size() >= CacheLimit)
        m_done.clear();
    m_done.insert(source, colors);
    if (colors.ok) {
        ++m_analysed;
        m_lastUs = us;
        emit sampled(source);
    }
}

void ArtPalette::startFile(const QString &source)
{
    QPointer<ArtPalette> self(this);
    QThreadPool::globalInstance()->start([self, source] {
        const QImage image = decodeFile(localPath(source));
        QElapsedTimer timer;
        timer.start();
        const ArtColors colors = analyse(image);
        const qint64 us = timer.nsecsElapsed() / 1000;
        post(self, source, colors, us);
    });
}

void ArtPalette::startDownload(const QString &source)
{
    QNetworkAccessManager *nam = m_engine ? m_engine->networkAccessManager() : nullptr;
    if (!nam) {
        finish(source, ArtColors(), 0);
        return;
    }
    QNetworkRequest request{QUrl(source)};
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(DownloadTimeoutMs);   // a stalled server ends as a failure, not a source pending for ever
    QNetworkReply *reply = nam->get(request);
    QPointer<ArtPalette> self(this);
    connect(reply, &QNetworkReply::downloadProgress, reply, [reply](qint64 got, qint64) {
        if (got > MaxDownloadBytes)
            reply->abort();
    });
    connect(reply, &QNetworkReply::finished, this, [self, source, reply] {
        reply->deleteLater();
        if (!self)
            return;
        if (reply->error() != QNetworkReply::NoError) {
            self->finish(source, ArtColors(), 0);
            return;
        }
        const QByteArray bytes = reply->readAll();
        QThreadPool::globalInstance()->start([self, source, bytes] {
            const QImage image = decodeBytes(bytes);
            QElapsedTimer timer;
            timer.start();
            const ArtColors colors = analyse(image);
            const qint64 us = timer.nsecsElapsed() / 1000;
            post(self, source, colors, us);
        });
    });
}
