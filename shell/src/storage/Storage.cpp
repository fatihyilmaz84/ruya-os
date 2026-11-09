#include "Storage.h"

#include "DBusStorageBackend.h"
#include "MockStorageBackend.h"

#include <QLocale>

#include <algorithm>
#include <utility>

Storage::Storage(std::unique_ptr<StorageBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    m_groupTimer.setSingleShot(true);
    m_groupTimer.setInterval(GroupWindowMs);
    connect(&m_groupTimer, &QTimer::timeout, this, &Storage::flushArrivals);
    connect(m_backend.get(), &StorageBackend::volumeAdded, this, [this](const QString &id) { m_pendingAdded.insert(id); });
    connect(m_backend.get(), &StorageBackend::volumesListed, this, [this](const QList<StorageVolume> &list) {
        QVariantList out;
        for (const StorageVolume &v : list) {
            out.append(QVariantMap{
                {QStringLiteral("id"), v.id},
                {QStringLiteral("drive"), v.drive},
                {QStringLiteral("label"), v.label},
                {QStringLiteral("filesystem"), v.filesystem},
                {QStringLiteral("sizeBytes"), v.sizeBytes},
                {QStringLiteral("freeBytes"), v.freeBytes},
                {QStringLiteral("removable"), v.removable},
                {QStringLiteral("mounted"), v.mounted},
                {QStringLiteral("mountPoint"), v.mountPoint},
                {QStringLiteral("readOnly"), v.readOnly},
            });
        }
        // A scan is of the volume as it was: gone with the volume, and with anything that changes it
        // (free space, mount point), as the service drops it too.
        bool scansDropped = false;
        for (auto it = m_scans.begin(); it != m_scans.end();) {
            const auto now = std::find_if(list.cbegin(), list.cend(), [&](const StorageVolume &v) { return v.id == it.key(); });
            const bool same = now != list.cend()
                && m_scanned.value(it.key()) == QVariantList{now->mountPoint, now->sizeBytes, now->freeBytes, now->readOnly};
            if (same) {
                ++it;
            } else {
                m_scanned.remove(it.key());
                it = m_scans.erase(it);
                scansDropped = true;
            }
        }
        m_volumes = out;
        emit volumesChanged();
        if (scansDropped)
            emit scansChanged(); // after the list: a client has the new rows by then
        for (const StorageVolume &v : list) {
            if (!m_pendingAdded.remove(v.id))
                continue;
            // A drive without an id (an old service) is its own group.
            const QString drive = v.drive.isEmpty() ? v.id : v.drive;
            auto it = std::find_if(m_arrivals.begin(), m_arrivals.end(), [&](const Arrival &a) { return a.drive == drive; });
            if (it == m_arrivals.end()) {
                m_arrivals.append({drive, {}});
                it = m_arrivals.end() - 1;
            }
            it->volumes.append(v);
            if (!m_groupTimer.isActive())
                m_groupTimer.start();
        }
    });
    connect(m_backend.get(), &StorageBackend::usageListed, this, [this](const SystemUsage &u) {
        m_internal = QVariantMap{
            {QStringLiteral("valid"), true},
            {QStringLiteral("totalBytes"), u.totalBytes},
            {QStringLiteral("freeBytes"), u.freeBytes},
            {QStringLiteral("appsBytes"), u.appsBytes},
            {QStringLiteral("dataBytes"), u.dataBytes},
            {QStringLiteral("systemBytes"), u.systemBytes},
        };
        emit internalChanged();
    });
    connect(m_backend.get(), &StorageBackend::scanListed, this, [this](const QString &id, const VolumeScan &scan) {
        // The volume as it is now, to tell later whether the scan still describes it.
        const QVariantList fingerprint = fingerprintOf(id);
        if (fingerprint.isEmpty())
            return; // the volume left before the reply came
        m_scanned.insert(id, fingerprint);
        QVariantList categories;
        for (const DriveCategory &c : scan.categories) {
            categories.append(QVariantMap{
                {QStringLiteral("key"), c.key},
                {QStringLiteral("bytes"), c.bytes},
                {QStringLiteral("files"), c.files},
            });
        }
        m_scans.insert(id, QVariantMap{
            {QStringLiteral("valid"), true},
            {QStringLiteral("state"), scan.state},
            {QStringLiteral("partial"), scan.partial},
            {QStringLiteral("usedBytes"), scan.usedBytes},
            {QStringLiteral("otherBytes"), scan.otherBytes},
            {QStringLiteral("categories"), categories},
            {QStringLiteral("status"), QString()},
        });
        emit scansChanged();
    });
    connect(m_backend.get(), &StorageBackend::scanStatus, this, [this](const QString &id, const QString &status) {
        const QVariantList fingerprint = fingerprintOf(id);
        if (fingerprint.isEmpty())
            return;
        m_scanned.insert(id, fingerprint);
        m_scans.insert(id, QVariantMap{
            {QStringLiteral("valid"), true},
            {QStringLiteral("state"), QStringLiteral("idle")},
            {QStringLiteral("partial"), false},
            {QStringLiteral("usedBytes"), qint64(0)},
            {QStringLiteral("otherBytes"), qint64(0)},
            {QStringLiteral("categories"), QVariantList()},
            {QStringLiteral("status"), status},
        });
        emit scansChanged();
    });
    connect(m_backend.get(), &StorageBackend::finished, this, &Storage::finished);
    m_internal = unknownInternal();
    m_backend->refresh();
    m_backend->refreshUsage();
}

Storage::~Storage() = default;

QVariantMap Storage::unknownInternal()
{
    return QVariantMap{
        {QStringLiteral("valid"), false},
        {QStringLiteral("totalBytes"), qint64(-1)},
        {QStringLiteral("freeBytes"), qint64(-1)},
        {QStringLiteral("appsBytes"), qint64(-1)},
        {QStringLiteral("dataBytes"), qint64(-1)},
        {QStringLiteral("systemBytes"), qint64(-1)},
    };
}

void Storage::refreshInternal()
{
    m_backend->refreshUsage();
}

QVariantList Storage::fingerprintOf(const QString &id) const
{
    for (const QVariant &v : m_volumes) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("id")).toString() == id) {
            return {m.value(QStringLiteral("mountPoint")), m.value(QStringLiteral("sizeBytes")),
                    m.value(QStringLiteral("freeBytes")), m.value(QStringLiteral("readOnly"))};
        }
    }
    return {};
}

void Storage::scan(const QString &id)
{
    m_backend->scanVolume(id);
}

void Storage::cancelScan(const QString &id)
{
    m_backend->cancelScan(id);
}

void Storage::flushArrivals()
{
    const QList<Arrival> arrivals = std::exchange(m_arrivals, {});
    QSet<QString> listed; // what is in the list now: a stick pulled within the window is not announced
    for (const QVariant &v : std::as_const(m_volumes))
        listed.insert(v.toMap().value(QStringLiteral("id")).toString());
    for (const Arrival &a : arrivals) {
        // Partitions we do not mount (filesystem "unknown") stay in the list but do not announce
        // the drive.
        QList<StorageVolume> usable;
        QSet<QString> counted; // a volume plugged in twice within the window counts once
        for (const StorageVolume &v : a.volumes) {
            if (v.filesystem != QLatin1String("unknown") && listed.contains(v.id) && !counted.contains(v.id)) {
                counted.insert(v.id);
                usable.append(v);
            }
        }
        if (!usable.isEmpty())
            emit driveAdded(a.drive, usable.constFirst().label, int(usable.size()));
    }
}

Storage *Storage::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<StorageBackend> backend;
    // Like Audio, Network and Bluetooth: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockStorageBackend>();
    else
        backend = std::make_unique<DBusStorageBackend>();
    return new Storage(std::move(backend));
}

QString Storage::formatBytes(qint64 bytes)
{
    // The shell language (QLocale::setDefault follows it), not the system's; a trailing zero
    // decimal is dropped: "1.5 GB", "32 GB".
    const QLocale locale;
    QString text = locale.formattedDataSize(bytes < 0 ? 0 : bytes, 1, QLocale::DataSizeSIFormat);
    const QString zero = locale.decimalPoint() + QLatin1Char('0');
    const int at = text.indexOf(zero);
    if (at >= 0 && (at + zero.size() == text.size() || !text.at(at + zero.size()).isDigit()))
        text.remove(at, zero.size());
    return text;
}

void Storage::eject(const QString &id)
{
    m_backend->eject(id);
}

void Storage::saveReport(const QString &id, const QVariantMap &files)
{
    QMap<QString, QString> texts;
    for (auto it = files.cbegin(); it != files.cend(); ++it)
        texts.insert(it.key(), it.value().toString());
    m_backend->saveReport(id, texts);
}

QVariantMap Storage::mockSavedFiles() const
{
    QVariantMap out;
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get())) {
        const auto saved = mock->savedFiles();
        for (auto it = saved.cbegin(); it != saved.cend(); ++it)
            out.insert(it.key(), it.value());
    }
    return out;
}

int Storage::mockSaveCalls() const
{
    auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get());
    return mock ? mock->saveCalls() : 0;
}

void Storage::mockSetSaveStatus(const QString &status)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->setSaveStatus(status);
}

void Storage::mockPlug(const QStringList &ids)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->plug(ids);
}

void Storage::mockReset(bool plugStick)
{
    m_arrivals.clear();
    m_groupTimer.stop();
    m_pendingAdded.clear();
    if (!m_scans.isEmpty()) {
        m_scans.clear();
        m_scanned.clear();
        emit scansChanged();
    }
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->reset(plugStick);
}

void Storage::mockPlugStick()
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->plugStick();
}

void Storage::mockHoldEject(bool hold)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->holdEject(hold);
}

int Storage::mockEjectCalls() const
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        return mock->ejectCalls();
    return 0;
}

void Storage::mockRepublish()
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->republish();
}

void Storage::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get())) {
        mock->setReplyDelay(ms);
        mock->refresh();
        mock->setReplyDelay(0);
    }
}

int Storage::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}

void Storage::mockSetInternal(double total, double free, double apps, double data)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->setUsage(qint64(total), qint64(free), qint64(apps), qint64(data));
}

int Storage::mockUsageCalls() const
{
    auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get());
    return mock ? mock->usageCalls() : 0;
}

void Storage::mockLowSpace(bool low)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->lowSpace(low);
}

void Storage::mockRefreshInternalDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get())) {
        mock->setReplyDelay(ms);
        mock->refreshUsage();
        mock->setReplyDelay(0);
    }
}

void Storage::mockHoldScan(bool hold)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->holdScan(hold);
}

QStringList Storage::mockScanCalls() const
{
    auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get());
    return mock ? mock->scanCalls() : QStringList();
}

QStringList Storage::mockCancelCalls() const
{
    auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get());
    return mock ? mock->cancelCalls() : QStringList();
}

void Storage::mockSetScanPartial(bool partial)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->setScanPartial(partial);
}

void Storage::mockSetScanFailed(bool failed)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->setScanFailed(failed);
}

void Storage::mockRefreshScanDelayed(const QString &id, int ms)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->refreshScanDelayed(id, ms);
}

void Storage::mockSetLabel(const QString &id, const QString &label)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->setLabel(id, label);
}

void Storage::mockSetFree(const QString &id, double freeBytes)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->setFree(id, qint64(freeBytes));
}

void Storage::mockSetBusy(const QString &id, bool busy)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->setBusy(id, busy);
}
