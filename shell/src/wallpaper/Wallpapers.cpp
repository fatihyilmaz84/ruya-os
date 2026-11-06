#include "Wallpapers.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QBuffer>
#include <QImage>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLinearGradient>
#include <QMetaObject>
#include <QPainter>
#include <QSaveFile>
#include <QScreen>
#include <QStandardPaths>
#include <QThread>
#include <QThreadPool>
#include <QUrl>

#include <algorithm>
#include <cmath>
#include <vector>

namespace {

constexpr int JpegQuality = 88;
constexpr qreal TargetContrast = 4.52;    // 04 §7 asks 4.5; the margin keeps colour rounding (16-bit channels) above it
constexpr qreal MaxRequiredDim = 0.85;
const QString UserPrefix = QStringLiteral("user:");

bool useMock()
{
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    return choice == QLatin1String("mock");
#else
    return choice != QLatin1String("dbus");
#endif
}

bool isPictureName(const QString &name)
{
    const QString suffix = QFileInfo(name).suffix().toLower();
    return suffix == QLatin1String("jpg") || suffix == QLatin1String("jpeg") || suffix == QLatin1String("png")
        || suffix == QLatin1String("webp");
}

bool isPictureFormat(const QByteArray &format)
{
    return format == "jpeg" || format == "png" || format == "webp";
}

// What a picture looks like to the reader without decoding it: false for a file that is not a
// picture we read, or is over the size limits.
enum class Probe { Ok, Unsupported, Unreadable, TooLarge };

Probe probe(const QString &path, QSize *size)
{
    const QFileInfo info(path);
    if (!info.isFile() || info.isSymLink() || info.size() <= 0)
        return Probe::Unreadable;
    if (info.size() > Wallpapers::MaxSourceBytes)
        return Probe::TooLarge;
    QImageReader reader(path);
    reader.setDecideFormatFromContent(true);
    if (!isPictureFormat(reader.format()))
        return reader.format().isEmpty() ? Probe::Unreadable : Probe::Unsupported;
    const QSize found = reader.size();
    if (!found.isValid())
        return Probe::Unreadable;
    if (qint64(found.width()) * found.height() > Wallpapers::MaxSourcePixels)
        return Probe::TooLarge;
    if (size)
        *size = found;
    return Probe::Ok;
}

// A name from a drive: no control characters, one line, at most 40 characters.
QString safeName(QString name)
{
    QString printable;
    for (const QChar c : std::as_const(name)) {
        if (c.isPrint())
            printable.append(c);
    }
    name = printable.simplified();
    if (name.size() > 40)
        name = name.left(40).trimmed();
    return name.isEmpty() ? QStringLiteral("Wallpaper") : name;
}

} // namespace

struct Wallpapers::Encoded
{
    QString status = QStringLiteral("io");
    QByteArray jpeg;
    QString name;
    qreal peak = 0;
    qreal floor = 0;
    QSize size;
};

Wallpapers::Wallpapers(QObject *parent)
    : QObject(parent)
    , m_mock(useMock())
{
    const QString fixed = qEnvironmentVariable("RUYA_WALLPAPER_DIR");
    if (!fixed.isEmpty()) {
        m_dir = fixed;
    } else if (qEnvironmentVariableIntValue("RUYA_SETTINGS_EPHEMERAL") != 0) {
        // Tests: a directory of their own, gone with the singleton.
        m_tempDir = std::make_unique<QTemporaryDir>();
        m_dir = m_tempDir->path();
    } else {
        m_dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + QStringLiteral("/wallpapers");
    }
    QDir().mkpath(m_dir);
    loadBundled();
    loadUser();
}

Wallpapers::~Wallpapers() = default;

Wallpapers *Wallpapers::create(QQmlEngine *, QJSEngine *)
{
    return new Wallpapers;
}

void Wallpapers::loadBundled()
{
    const QString base = QStringLiteral(":/qt/qml/RuyaShell/assets/wallpapers/");
    QFile file(base + QStringLiteral("catalog.json"));
    if (!file.open(QIODevice::ReadOnly)) {
        qWarning("ruya-shell: the wallpaper catalogue is missing");
        return;
    }
    const QJsonArray items = QJsonDocument::fromJson(file.readAll()).array();
    for (const QJsonValue &value : items) {
        const QJsonObject o = value.toObject();
        const QString id = o.value(QStringLiteral("id")).toString();
        if (id.isEmpty())
            continue;
        QString name = id;
        name[0] = name.at(0).toUpper();
        m_bundled.append(QVariantMap{
            {QStringLiteral("id"), id},
            {QStringLiteral("name"), name},
            {QStringLiteral("source"), QStringLiteral("qrc") + base + o.value(QStringLiteral("file")).toString()},
            {QStringLiteral("peak"), o.value(QStringLiteral("peak")).toDouble()},
            {QStringLiteral("floor"), o.value(QStringLiteral("floor")).toDouble()},
        });
    }
}

QVariantMap Wallpapers::userEntry(const QString &dir, const QString &file, const QString &name, qreal peak, qreal floor,
                                  const QSize &size, qint64 bytes)
{
    return QVariantMap{
        {QStringLiteral("id"), UserPrefix + file},
        {QStringLiteral("name"), name},
        {QStringLiteral("source"), QUrl::fromLocalFile(dir + QLatin1Char('/') + file).toString()},
        {QStringLiteral("peak"), peak},
        {QStringLiteral("floor"), floor},
        {QStringLiteral("width"), size.width()},
        {QStringLiteral("height"), size.height()},
        {QStringLiteral("sizeBytes"), bytes},
    };
}

// The index lists the copies; a file that is not in it is a leftover (a crash between the file and
// the index) and is removed, so the directory never fills with pictures nobody can see.
void Wallpapers::loadUser()
{
    m_user.clear();
    QFile file(m_dir + QStringLiteral("/index.json"));
    QStringList kept;
    if (file.open(QIODevice::ReadOnly)) {
        const QJsonArray items = QJsonDocument::fromJson(file.readAll()).object().value(QStringLiteral("items")).toArray();
        for (const QJsonValue &value : items) {
            const QJsonObject o = value.toObject();
            const QString name = o.value(QStringLiteral("file")).toString();
            // A file name only, never a path.
            if (name.isEmpty() || name.contains(QLatin1Char('/')) || name.contains(QLatin1Char('\\')) || name.startsWith(QLatin1Char('.')))
                continue;
            const QFileInfo info(m_dir + QLatin1Char('/') + name);
            if (!info.isFile() || m_user.size() >= UserLimit)
                continue;
            QImageReader reader(info.filePath());
            m_user.append(userEntry(m_dir, name, o.value(QStringLiteral("name")).toString(),
                                    o.value(QStringLiteral("peak")).toDouble(), o.value(QStringLiteral("floor")).toDouble(),
                                    reader.size(), info.size()));
            kept.append(name);
        }
    }
    // Only what this class writes (u-<hash>.jpg): RUYA_WALLPAPER_DIR may be a folder with other things in it.
    const QStringList files = QDir(m_dir).entryList({QStringLiteral("u-*.jpg")}, QDir::Files);
    for (const QString &leftover : files) {
        if (!kept.contains(leftover))
            QFile::remove(m_dir + QLatin1Char('/') + leftover);
    }
}

void Wallpapers::saveIndex() const
{
    QJsonArray items;
    for (const QVariant &v : m_user) {
        const QVariantMap m = v.toMap();
        items.append(QJsonObject{
            {QStringLiteral("file"), m.value(QStringLiteral("id")).toString().mid(UserPrefix.size())},
            {QStringLiteral("name"), m.value(QStringLiteral("name")).toString()},
            {QStringLiteral("peak"), m.value(QStringLiteral("peak")).toDouble()},
            {QStringLiteral("floor"), m.value(QStringLiteral("floor")).toDouble()},
        });
    }
    QSaveFile file(m_dir + QStringLiteral("/index.json"));
    if (!file.open(QIODevice::WriteOnly)) {
        qWarning("ruya-shell: cannot write the wallpaper index");
        return;
    }
    file.write(QJsonDocument(QJsonObject{{QStringLiteral("version"), 1}, {QStringLiteral("items"), items}}).toJson());
    if (!file.commit())
        qWarning("ruya-shell: cannot write the wallpaper index");
}

namespace {

double toLinear(double s)
{
    return s <= 0.04045 ? s / 12.92 : std::pow((s + 0.055) / 1.055, 2.4);
}

double toSrgb(double l)
{
    return l <= 0.0031308 ? l * 12.92 : 1.055 * std::pow(l, 1.0 / 2.4) - 0.055;
}

double luminanceOf(double r, double g, double b)   // sRGB channels 0..1
{
    return 0.2126 * toLinear(r) + 0.7152 * toLinear(g) + 0.0722 * toLinear(b);
}

double contrastOf(double a, double b)
{
    const double hi = std::max(a, b);
    const double lo = std::min(a, b);
    return (hi + 0.05) / (lo + 0.05);
}

// The luminance of a grey of luminance `grey` under a layer of colour `layer` at alpha `a` (sRGB blend).
double underLayer(double grey, const QColor &layer, double a)
{
    const double s = toSrgb(grey);
    auto mix = [&](double c) { return (1 - a) * s + a * c; };
    return luminanceOf(mix(layer.redF()), mix(layer.greenF()), mix(layer.blueF()));
}

} // namespace

qreal Wallpapers::requiredDim(qreal peak, qreal floor, const QColor &background, const QColor &text)
{
    const double textLum = luminanceOf(text.redF(), text.greenF(), text.blueF());
    const double layerLum = luminanceOf(background.redF(), background.greenF(), background.blueF());
    const double worst = textLum >= layerLum ? peak : floor;   // lighter text: the bright part is worst
    auto passes = [&](double a) { return contrastOf(textLum, underLayer(worst, background, a)) >= TargetContrast; };
    if (passes(0))
        return 0;
    if (!passes(MaxRequiredDim))
        return MaxRequiredDim;
    double lo = 0;
    double hi = MaxRequiredDim;    // hi always passes
    for (int i = 0; i < 32; ++i) {
        const double mid = (lo + hi) / 2;
        (passes(mid) ? hi : lo) = mid;
    }
    return hi;
}

// The 5th and 95th percentile of the relative luminance of a 64x36 reduction.
void Wallpapers::extremesOf(const QImage &image, qreal *floor, qreal *peak)
{
    const QImage small = image.scaled(64, 36, Qt::IgnoreAspectRatio, Qt::SmoothTransformation).convertToFormat(QImage::Format_RGB32);
    std::vector<double> values;
    values.reserve(size_t(small.width()) * small.height());
    for (int y = 0; y < small.height(); ++y) {
        const QRgb *line = reinterpret_cast<const QRgb *>(small.constScanLine(y));
        for (int x = 0; x < small.width(); ++x)
            values.push_back(luminanceOf(qRed(line[x]) / 255.0, qGreen(line[x]) / 255.0, qBlue(line[x]) / 255.0));
    }
    std::sort(values.begin(), values.end());
    auto at = [&](double q) { return values.empty() ? 0.0 : values[std::min(values.size() - 1, size_t(std::floor(q * (values.size() - 1) + 0.5)))]; };
    *floor = at(0.05);
    *peak = at(0.95);
}

QSize Wallpapers::targetSize() const
{
    QSize screen(1920, 1080);
    if (const QScreen *s = QGuiApplication::primaryScreen())
        screen = (s->size() * s->devicePixelRatio()).expandedTo(QSize(1, 1));
    return screen.boundedTo(QSize(MaxWidth, MaxHeight));
}

QString Wallpapers::mapMount(const QString &mountPoint) const
{
    // The mock stick has no real mount: its path is read from the mock tree, when there is one.
    const QString mockBase = QStringLiteral("/run/media/mock/");
    if (m_mock && m_mockUsb && mountPoint.startsWith(mockBase))
        return m_mockUsb->path() + QLatin1Char('/') + mountPoint.mid(mockBase.size());
    return mountPoint;
}

void Wallpapers::scanUsb(const QStringList &mountPoints)
{
    const quint64 serial = ++m_scanSerial;
    QStringList roots;
    for (const QString &mount : mountPoints) {
        if (!mount.isEmpty())
            roots.append(mapMount(mount));
    }
    QPointer<Wallpapers> self(this);
    QThreadPool::globalInstance()->start([self, serial, roots, mountPoints] {
        QVariantList found;
        for (int i = 0; i < roots.size(); ++i) {
            const QDir root(roots.at(i));
            const QString volume = QFileInfo(mountPoints.at(i)).fileName();
            const QStringList folders = root.entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks, QDir::Name | QDir::IgnoreCase);
            for (const QString &folder : folders) {
                const QString lower = folder.toLower();
                if (lower != QLatin1String("wallpapers") && lower != QLatin1String("pictures"))
                    continue;
                const QDir dir(root.filePath(folder));
                const QFileInfoList files = dir.entryInfoList(QDir::Files | QDir::NoSymLinks, QDir::Name | QDir::IgnoreCase);
                int probed = 0;
                for (const QFileInfo &info : files) {
                    if (!isPictureName(info.fileName()) || info.size() <= 0 || info.size() > MaxSourceBytes)
                        continue;
                    if (++probed > MaxProbedPerFolder)
                        break;                   // a folder of thousands: look at the first ones only
                    QSize size;
                    if (probe(info.filePath(), &size) != Probe::Ok)
                        continue;
                    found.append(QVariantMap{
                        {QStringLiteral("path"), info.filePath()},
                        {QStringLiteral("name"), safeName(info.completeBaseName())},
                        {QStringLiteral("source"), QUrl::fromLocalFile(info.filePath()).toString()},
                        {QStringLiteral("sizeBytes"), info.size()},
                        {QStringLiteral("volume"), volume},
                    });
                }
            }
        }
        std::stable_sort(found.begin(), found.end(), [](const QVariant &a, const QVariant &b) {
            return a.toMap().value(QStringLiteral("name")).toString().compare(b.toMap().value(QStringLiteral("name")).toString(), Qt::CaseInsensitive) < 0;
        });
        while (found.size() > MaxListed)
            found.removeLast();
        QMetaObject::invokeMethod(qApp, [self, serial, found] {
            if (!self || serial != self->m_scanSerial)
                return;                      // a newer scan was asked for meanwhile
            self->m_usbImages = found;
            emit self->usbImagesChanged();
        }, Qt::QueuedConnection);
    });
}

void Wallpapers::finish(const QString &status, const QString &id, const QString &name)
{
    m_copying = false;
    emit copyStateChanged();
    emit copyFinished(status, id, name);
}

void Wallpapers::importFile(const QString &path, const QColor &flatten)
{
    // Only what the list offered: the shell never reads another path on a caller's say-so.
    bool listed = false;
    for (const QVariant &v : std::as_const(m_usbImages))
        listed = listed || v.toMap().value(QStringLiteral("path")).toString() == path;
    if (!listed && !m_copying) {
        m_copying = true;
        emit copyStateChanged();
        qWarning("ruya-shell: wallpaper import refused: not a listed picture");
        QMetaObject::invokeMethod(this, [this] { finish(QStringLiteral("unreadable")); }, Qt::QueuedConnection);
        return;
    }
    startImport(path, flatten);
}

void Wallpapers::mockImportAny(const QString &path, const QColor &flatten)
{
    if (m_mock)
        startImport(path, flatten);
}

void Wallpapers::startImport(const QString &path, const QColor &flatten)
{
    if (m_copying)
        return;
    m_copying = true;
    emit copyStateChanged();
    if (m_user.size() >= UserLimit) {
        // Answered asynchronously like every other outcome.
        QMetaObject::invokeMethod(this, [this] { finish(QStringLiteral("limit")); }, Qt::QueuedConnection);
        return;
    }
    const QSize target = targetSize();
    const int delay = m_copyDelayMs;
    QPointer<Wallpapers> self(this);
    QThreadPool::globalInstance()->start([self, path, target, delay, flatten] {
        Encoded out;
        if (delay > 0)
            QThread::msleep(ulong(delay));
        QSize size;
        switch (probe(path, &size)) {
        case Probe::Unsupported: out.status = QStringLiteral("unsupported"); break;
        case Probe::Unreadable: out.status = QStringLiteral("unreadable"); break;
        case Probe::TooLarge: out.status = QStringLiteral("too-large"); break;
        case Probe::Ok: {
            QImageReader reader(path);
            reader.setDecideFormatFromContent(true);
            reader.setAutoTransform(true);
            // The scale that covers the screen, never above 1 (no enlarging) and never past the cap.
            QSize oriented = size;
            if (reader.transformation() & QImageIOHandler::TransformationRotate90)
                oriented.transpose();
            qreal scale = std::max(qreal(target.width()) / oriented.width(), qreal(target.height()) / oriented.height());
            scale = std::min({scale, 1.0, qreal(MaxWidth) / oriented.width(), qreal(MaxHeight) / oriented.height()});
            if (scale < 1.0) {
                QSize scaled(std::max(1, int(std::lround(oriented.width() * scale))), std::max(1, int(std::lround(oriented.height() * scale))));
                if (reader.transformation() & QImageIOHandler::TransformationRotate90)
                    scaled.transpose();
                reader.setScaledSize(scaled);
            }
            QImage image = reader.read();
            if (image.isNull()) {
                out.status = QStringLiteral("unreadable");
                break;
            }
            QImage flat(image.size(), QImage::Format_RGB32);
            flat.fill(flatten.isValid() ? flatten : QColor(Qt::black));
            {
                QPainter painter(&flat);
                painter.drawImage(0, 0, image);
            }
            QBuffer buffer(&out.jpeg);
            buffer.open(QIODevice::WriteOnly);
            if (!flat.save(&buffer, "JPEG", JpegQuality)) {
                out.jpeg.clear();
                break;                       // "io"
            }
            out.status = QStringLiteral("ok");
            out.size = flat.size();
            extremesOf(flat, &out.floor, &out.peak);
            out.name = safeName(QFileInfo(path).completeBaseName());
            break;
        }
        }
        // Back on the GUI thread through the application object; the QPointer is read only there.
        QMetaObject::invokeMethod(qApp, [self, out] {
            if (self)
                self->finishImport(out);
        }, Qt::QueuedConnection);
    });
}

void Wallpapers::finishImport(const Encoded &result)
{
    if (result.status != QLatin1String("ok")) {
        qWarning("ruya-shell: wallpaper import failed (%s)", qPrintable(result.status));
        finish(result.status);
        return;
    }
    // The same picture twice is one copy: the file name is the hash of what is stored.
    const QString file = QStringLiteral("u-")
        + QString::fromLatin1(QCryptographicHash::hash(result.jpeg, QCryptographicHash::Sha1).toHex().left(12))
        + QStringLiteral(".jpg");
    const QString id = UserPrefix + file;
    for (const QVariant &v : std::as_const(m_user)) {
        if (v.toMap().value(QStringLiteral("id")).toString() == id) {
            finish(QStringLiteral("ok"), id, v.toMap().value(QStringLiteral("name")).toString());
            return;
        }
    }
    if (m_user.size() >= UserLimit) {
        finish(QStringLiteral("limit"));
        return;
    }
    QSaveFile out(m_dir + QLatin1Char('/') + file);
    if (!out.open(QIODevice::WriteOnly) || out.write(result.jpeg) != result.jpeg.size() || !out.commit()) {
        qWarning("ruya-shell: cannot store the wallpaper in %s", qPrintable(m_dir));
        finish(QStringLiteral("io"));
        return;
    }
    m_user.append(userEntry(m_dir, file, result.name, result.peak, result.floor, result.size, result.jpeg.size()));
    saveIndex();
    emit userChanged();
    finish(QStringLiteral("ok"), id, result.name);
}

bool Wallpapers::remove(const QString &id)
{
    if (!id.startsWith(UserPrefix))
        return false;
    for (int i = 0; i < m_user.size(); ++i) {
        if (m_user.at(i).toMap().value(QStringLiteral("id")).toString() != id)
            continue;
        QFile::remove(m_dir + QLatin1Char('/') + id.mid(UserPrefix.size()));
        m_user.removeAt(i);
        saveIndex();
        emit userChanged();
        return true;
    }
    return false;
}

// ---- tests only -------------------------------------------------------------------------------

namespace {

QImage testPicture(int width, int height, QColor from, QColor to)
{
    QImage image(width, height, QImage::Format_RGB32);
    QPainter painter(&image);
    QLinearGradient gradient(0, 0, width, height);
    gradient.setColorAt(0, from);
    gradient.setColorAt(1, to);
    painter.fillRect(image.rect(), gradient);
    painter.setPen(Qt::NoPen);
    painter.setBrush(QColor(255, 255, 255, 90));
    painter.drawEllipse(QPointF(width * 0.7, height * 0.3), height * 0.2, height * 0.2);
    return image;
}

} // namespace

QString Wallpapers::mockPrepareUsb()
{
    if (!m_mock)
        return QString();
    m_mockUsb = std::make_unique<QTemporaryDir>();
    const QString root = m_mockUsb->path() + QStringLiteral("/Ruya Stick");
    for (const char *folder : {"Wallpapers", "Wallpapers/nested", "Pictures", "Other"})
        QDir().mkpath(root + QLatin1Char('/') + QLatin1String(folder));
    testPicture(3000, 2000, QColor(20, 60, 160), QColor(200, 80, 140)).save(root + QStringLiteral("/Wallpapers/sunset.jpg"), "JPEG", 90);
    testPicture(640, 360, QColor(10, 90, 70), QColor(40, 160, 120)).save(root + QStringLiteral("/Wallpapers/tiny.png"), "PNG");
    testPicture(2400, 1350, QColor(255, 255, 255), QColor(245, 245, 250)).save(root + QStringLiteral("/Wallpapers/Bright.PNG"), "PNG");
    testPicture(1600, 1200, QColor(120, 40, 40), QColor(220, 160, 60)).save(root + QStringLiteral("/Pictures/photo.jpg"), "JPEG", 90);
    testPicture(800, 450, QColor(1, 2, 3), QColor(4, 5, 6)).save(root + QStringLiteral("/Other/hidden.jpg"), "JPEG");
    testPicture(800, 450, QColor(1, 2, 3), QColor(4, 5, 6)).save(root + QStringLiteral("/Wallpapers/nested/deep.jpg"), "JPEG");
    testPicture(800, 450, QColor(1, 2, 3), QColor(4, 5, 6)).save(root + QStringLiteral("/top.jpg"), "JPEG");
    testPicture(320, 180, QColor(1, 2, 3), QColor(4, 5, 6)).save(root + QStringLiteral("/Wallpapers/old.bmp"), "BMP");
    // Not pictures, or over the limits: not listed (and refused by importFile).
    QFile garbage(root + QStringLiteral("/Wallpapers/broken.jpg"));
    if (garbage.open(QIODevice::WriteOnly))
        garbage.write("this is not a jpeg");
    garbage.close();
    QFile notes(root + QStringLiteral("/Wallpapers/notes.txt"));
    if (notes.open(QIODevice::WriteOnly))
        notes.write("notes");
    notes.close();
    QImage huge(7000, 6000, QImage::Format_Grayscale8);   // 42 megapixels: over the pixel limit
    huge.fill(Qt::gray);
    huge.save(root + QStringLiteral("/Wallpapers/huge.png"), "PNG");
    return m_mockUsb->path();
}

QString Wallpapers::mockPlantCorrupt()
{
    if (!m_mock)
        return QString();
    const QString file = QStringLiteral("u-corrupt.jpg");
    QFile out(m_dir + QLatin1Char('/') + file);
    if (out.open(QIODevice::WriteOnly))
        out.write("not a picture");
    out.close();
    m_user.append(userEntry(m_dir, file, QStringLiteral("Corrupt"), 0.0, 0.0, QSize(), 13));
    saveIndex();
    emit userChanged();
    return UserPrefix + file;
}

void Wallpapers::mockFillUser(int count)
{
    if (!m_mock)
        return;
    for (int i = m_user.size(); i < std::min(count, int(UserLimit)); ++i) {
        const QString file = QStringLiteral("u-fill-%1.jpg").arg(i);
        const QImage picture = testPicture(64, 36, QColor(10 + i * 10, 40, 90), QColor(200, 30 + i * 8, 60));
        picture.save(m_dir + QLatin1Char('/') + file, "JPEG", 80);
        m_user.append(userEntry(m_dir, file, QStringLiteral("Filler %1").arg(i + 1), 0.1, 0.01, picture.size(), QFileInfo(m_dir + QLatin1Char('/') + file).size()));
    }
    saveIndex();
    emit userChanged();
}

void Wallpapers::mockSetCopyDelay(int ms)
{
    if (m_mock)
        m_copyDelayMs = ms;
}

void Wallpapers::mockReset()
{
    if (!m_mock)
        return;
    const QVariantList all = m_user;
    for (const QVariant &v : all)
        remove(v.toMap().value(QStringLiteral("id")).toString());
    m_usbImages.clear();
    emit usbImagesChanged();
}
