#pragma once

#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QSize>
#include <QString>
#include <QStringList>
#include <QTemporaryDir>
#include <QVariantList>

#include <memory>

// The wallpaper library (T-208, 04 §3.5): the bundled pictures, the pictures the owner copied
// from a USB drive into the shell's own state directory, and the listing of a drive's pictures.
// The chosen one is `DeviceSettings.wallpaper` ("" is the default look, an id from `bundled`, or
// "user:<file>" from `user`).
//
// A USB picture is never used in place: `importFile` copies it off the GUI thread, downscaled to
// the screen (at most 3840x2160, never enlarged) and re-encoded as JPEG, so removing the stick
// loses nothing. Nothing on a drive is ever run; files are only read, only regular files (no
// symlinks), only jpg/png/webp, limited in size, and the listing looks one folder level deep
// (`Wallpapers/` or `Pictures/`). The directory holds at most `UserLimit` pictures and an
// `index.json` (name and brightness of each).
class Wallpapers : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // [{ id, name, source, peak }]: the bundled pictures (ids "dusk", "aurora", ...). `name` is the
    // English name; the UI translates by id. `peak` is the brightness of the picture's bright
    // part (0..1, linear light), see requiredDim.
    Q_PROPERTY(QVariantList bundled READ bundled CONSTANT)
    // [{ id, name, source, peak, width, height, sizeBytes }]: the copies, oldest first. id is "user:<file>".
    Q_PROPERTY(QVariantList user READ user NOTIFY userChanged)
    // [{ path, name, source, sizeBytes, volume }]: the pictures found on the drives given to the last
    // scanUsb(), by volume and name, at most MaxListed.
    Q_PROPERTY(QVariantList usbImages READ usbImages NOTIFY usbImagesChanged)
    // "idle" | "copying" while importFile works; the result comes as copyFinished.
    Q_PROPERTY(QString copyState READ copyState NOTIFY copyStateChanged)
    Q_PROPERTY(int userLimit READ userLimit CONSTANT)
    Q_PROPERTY(QString directory READ directory CONSTANT)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    static constexpr int UserLimit = 12;                         // copies kept
    static constexpr qint64 MaxSourceBytes = 25LL * 1024 * 1024; // a source file above this is refused
    static constexpr qint64 MaxSourcePixels = 40LL * 1000 * 1000; // so is a picture above 40 megapixels
    static constexpr int MaxListed = 60;                         // pictures listed from the drives
    static constexpr int MaxWidth = 3840;
    static constexpr int MaxHeight = 2160;

    explicit Wallpapers(QObject *parent = nullptr);
    ~Wallpapers() override;

    static Wallpapers *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList bundled() const { return m_bundled; }
    QVariantList user() const { return m_user; }
    QVariantList usbImages() const { return m_usbImages; }
    QString copyState() const { return m_copying ? QStringLiteral("copying") : QStringLiteral("idle"); }
    int userLimit() const { return UserLimit; }
    QString directory() const { return m_dir; }
    bool isMock() const { return m_mock; }

    // Looks for pictures on the given mount points (a mounted removable volume each): jpg, png and
    // webp files directly inside a folder named Wallpapers or Pictures (any case), regular files
    // only, within the size limits. Done off the GUI thread; usbImagesChanged follows (also for an
    // empty result). A newer call makes an older one's result be dropped.
    Q_INVOKABLE void scanUsb(const QStringList &mountPoints);
    // Copies one picture (a `path` from usbImages) into the library. copyState is "copying" at once;
    // copyFinished(status, id, name) follows: "ok" (id is the new "user:<file>"), "limit" (already
    // UserLimit copies), "unsupported" (not jpg/png/webp), "too-large", "unreadable" or "io".
    Q_INVOKABLE void importFile(const QString &path);
    // Deletes a copy ("user:<file>"). False for an unknown id or a bundled one.
    Q_INVOKABLE bool remove(const QString &id);

    // The least dim (0..0.75) over a picture of this peak brightness that keeps text of the
    // Theme.text colour at 4.5:1 (04 §7) over its bright part. 0 for a dark picture.
    Q_INVOKABLE static qreal requiredDim(qreal peak);

    // Tests only, and only with the mock backend (otherwise no-ops). mockPrepareUsb writes a tree of
    // pictures (see the .cpp) and makes the mock stick's mount point ("/run/media/mock/<label>")
    // read from it; it returns the path. mockPlantCorrupt adds a copy whose file is not a picture
    // and returns its id. mockFillUser adds copies of small made-up pictures until there are `count`
    // (to reach the limit). mockSetCopyDelay makes each import take this long (ms) on its worker.
    // mockReset deletes every copy.
    Q_INVOKABLE QString mockPrepareUsb();
    Q_INVOKABLE QString mockPlantCorrupt();
    Q_INVOKABLE void mockFillUser(int count);
    Q_INVOKABLE void mockSetCopyDelay(int ms);
    Q_INVOKABLE void mockReset();

signals:
    void userChanged();
    void usbImagesChanged();
    void copyStateChanged();
    void copyFinished(const QString &status, const QString &id, const QString &name);

private:
    struct Encoded;
    void loadBundled();
    void loadUser();
    void saveIndex() const;
    QString mapMount(const QString &mountPoint) const;
    QSize targetSize() const;
    void finishImport(const Encoded &result);
    void finish(const QString &status, const QString &id = QString(), const QString &name = QString());
    static qreal peakOf(const QImage &image);
    static QVariantMap userEntry(const QString &dir, const QString &file, const QString &name, qreal peak, const QSize &size, qint64 bytes);

    QString m_dir;
    std::unique_ptr<QTemporaryDir> m_tempDir; // the directory while settings are ephemeral (tests)
    bool m_mock = false;
    QVariantList m_bundled;
    QVariantList m_user;
    QVariantList m_usbImages;
    bool m_copying = false;
    quint64 m_scanSerial = 0;
    int m_copyDelayMs = 0;
    std::unique_ptr<QTemporaryDir> m_mockUsb;
};
