#include "MockStorageBackend.h"

#include <algorithm>
#include <utility>

namespace {
const QString StickId = QStringLiteral("vol-stick");
constexpr qint64 GB = 1000LL * 1000 * 1000;

SystemUsage usageOf(qint64 total, qint64 free, qint64 apps, qint64 data)
{
    SystemUsage u;
    u.totalBytes = total;
    u.freeBytes = free;
    u.appsBytes = apps;
    u.dataBytes = data;
    // As the service computes it: without the profile data (unknown today) the rest is everything
    // used that is not apps.
    const bool known = total >= 0 && free >= 0 && apps >= 0;
    u.systemBytes = known ? std::max<qint64>(0, total - free - apps - std::max<qint64>(0, data)) : -1;
    return u;
}
}

MockStorageBackend::MockStorageBackend(QObject *parent)
    : StorageBackend(parent)
{
    m_plugTimer.setSingleShot(true);
    m_plugTimer.setInterval(qEnvironmentVariable("RUYA_MOCK_FAST") == QLatin1String("1") ? 30 : 3000);
    connect(&m_plugTimer, &QTimer::timeout, this, &MockStorageBackend::plugStick);
    initState();
    // The tests set RUYA_MOCK_NO_STICK=1: a stick appearing by itself would toast in every test.
    if (qEnvironmentVariable("RUYA_MOCK_NO_STICK") != QLatin1String("1"))
        m_plugTimer.start();
}

void MockStorageBackend::refresh()
{
    publish(m_delay);
}

void MockStorageBackend::refreshUsage()
{
    ++m_usageCalls;
    publishUsage(m_delay);
}

void MockStorageBackend::setUsage(qint64 total, qint64 free, qint64 apps, qint64 data)
{
    m_usage = usageOf(total, free, apps, data);
    publishUsage();
}

void MockStorageBackend::lowSpace(bool low)
{
    if (low)
        setUsage(464 * GB, 28 * GB, 188 * GB, -1);
    else
        setUsage(464 * GB, 450 * GB, 6 * GB + GB / 2, -1);
}

void MockStorageBackend::eject(const QString &id)
{
    ++m_ejectCalls;
    if (m_holdEject) {
        m_heldEjects.append(id);
        return;
    }
    doEject(id);
}

void MockStorageBackend::saveReport(const QString &id, const QMap<QString, QString> &files)
{
    ++m_saveCalls;
    const int at = indexOf(id);
    QString status = QStringLiteral("ok");
    if (id.isEmpty() || files.isEmpty()) {
        status = QStringLiteral("invalid");
    } else if (at < 0 || !m_entries.at(at).present) {
        status = QStringLiteral("unknown-volume");
    } else if (!m_entries.at(at).vol.removable || !m_entries.at(at).vol.mounted) {
        status = QStringLiteral("unsupported");
    } else if (m_entries.at(at).vol.readOnly) {
        status = QStringLiteral("read-only");
    } else if (!m_saveStatus.isEmpty()) {
        status = m_saveStatus;
    }
    if (status == QLatin1String("ok"))
        m_saved = files;
    answer(QStringLiteral("saveReport"), id, status);
}

void MockStorageBackend::holdEject(bool hold)
{
    m_holdEject = hold;
    if (hold)
        return;
    const QStringList held = std::exchange(m_heldEjects, {});
    for (const QString &id : held)
        doEject(id);
}

void MockStorageBackend::republish()
{
    publish();
}

void MockStorageBackend::doEject(const QString &id)
{
    const int at = indexOf(id);
    QString status = QStringLiteral("ok");
    if (id.isEmpty()) {
        status = QStringLiteral("invalid");
    } else if (at < 0 || !m_entries.at(at).present) {
        status = QStringLiteral("unknown-volume");
    } else if (!m_entries.at(at).vol.removable) {
        status = QStringLiteral("failed");
    } else if (!m_entries.at(at).vol.mounted) {
        status = QStringLiteral("unsupported");
    } else if (m_entries.at(at).busy) {
        status = QStringLiteral("busy");
    } else {
        // Ejecting powers the drive off: all its partitions go.
        const QString drive = m_entries.at(at).vol.drive;
        for (Entry &e : m_entries) {
            if (e.vol.drive == drive)
                e.present = false;
        }
        dropScans(drive);
        publish();
    }
    answer(QStringLiteral("eject"), id, status);
}

void MockStorageBackend::plugStick()
{
    m_plugTimer.stop();
    plug({StickId});
}

void MockStorageBackend::plug(const QStringList &ids)
{
    QStringList added;
    for (const QString &id : ids) {
        const int at = indexOf(id);
        if (at < 0 || m_entries.at(at).present)
            continue;
        m_entries[at].present = true;
        m_entries[at].busy = false;
        added.append(id);
    }
    if (added.isEmpty())
        return;
    // Announced before the list that holds them, like the D-Bus signals.
    QTimer::singleShot(0, this, [this, added] {
        for (const QString &id : added)
            emit volumeAdded(id);
    });
    publish();
}

void MockStorageBackend::setBusy(const QString &id, bool busy)
{
    const int at = indexOf(id);
    if (at >= 0)
        m_entries[at].busy = busy;
}

void MockStorageBackend::setLabel(const QString &id, const QString &label)
{
    const int at = indexOf(id);
    if (at < 0)
        return;
    m_entries[at].vol.label = label;
    publish();
}

void MockStorageBackend::setFree(const QString &id, qint64 freeBytes)
{
    const int at = indexOf(id);
    if (at < 0)
        return;
    m_entries[at].vol.freeBytes = freeBytes;
    m_scans.remove(id); // the service drops a scan of a volume that changed
    if (m_scanning == id)
        m_scanning.clear();
    publish();
}

void MockStorageBackend::reset(bool plugStick)
{
    initState();
    publish();
    publishUsage();
    if (plugStick)
        m_plugTimer.start();
}

// No publishing here: the constructor runs before anybody listens. The stick is absent.
void MockStorageBackend::initState()
{
    m_holdEject = false;
    m_heldEjects.clear();
    m_ejectCalls = 0;
    m_saved.clear();
    m_saveCalls = 0;
    m_saveStatus.clear();
    m_scans.clear();
    m_scanning.clear();
    m_holdScan = false;
    m_scanPartial = false;
    m_scanFailed = false;
    m_scanCalls.clear();
    m_cancelCalls.clear();
    m_plugTimer.stop();
    m_usage = usageOf(464 * GB, 450 * GB, 6 * GB + GB / 2, -1);
    auto entry = [](const char *id, const char *drive, const char *label, const char *fs, qint64 size, qint64 free,
                    bool removable, bool mounted, const char *mountPoint, bool present) {
        Entry e;
        e.vol.id = QString::fromLatin1(id);
        e.vol.drive = QString::fromLatin1(drive);
        e.vol.label = QString::fromLatin1(label);
        e.vol.filesystem = QString::fromLatin1(fs);
        e.vol.sizeBytes = size;
        e.vol.freeBytes = free;
        e.vol.removable = removable;
        e.vol.mounted = mounted;
        e.vol.mountPoint = QString::fromLatin1(mountPoint);
        e.present = present;
        return e;
    };
    m_entries = {
        entry("vol-internal", "drive-internal", "Games disk", "ext4", 512 * GB, 318 * GB, false, true, "/var/mnt/games", true),
        entry("vol-old", "drive-old", "Old Drive", "unknown", 64 * GB, 0, true, false, "", true),
        entry("vol-stick", "drive-stick", "Ruya Stick", "exfat", 64 * GB, 44 * GB + GB / 2, true, true, "/run/media/mock/Ruya Stick", false),
        entry("vol-stick-2", "drive-stick", "Ruya Photos", "exfat", 16 * GB, 9 * GB, true, true, "/run/media/mock/Ruya Photos", false),
        entry("vol-stick-raw", "drive-stick", "Ruya Raw", "unknown", 8 * GB, 0, true, false, "", false),
        entry("vol-card", "drive-card", "Camera Card", "vfat", 64 * GB, 40 * GB, true, true, "/run/media/mock/Camera Card", false),
        entry("vol-odd", "drive-odd", "Odd Drive", "unknown", 4 * GB, 0, true, false, "", false),
    };
}

int MockStorageBackend::indexOf(const QString &id) const
{
    for (int i = 0; i < m_entries.size(); ++i) {
        if (m_entries.at(i).vol.id == id)
            return i;
    }
    return -1;
}

// Asynchronous like the real service; the internal disk comes first, the rest in a stable order.
void MockStorageBackend::publish(int delayMs)
{
    QList<StorageVolume> list;
    for (const Entry &e : std::as_const(m_entries)) {
        if (e.present)
            list.append(e.vol);
    }
    const quint64 request = beginRequest();
    if (delayMs > 0)
        ++m_pending;
    QTimer::singleShot(delayMs, this, [this, request, list, delayMs] {
        if (delayMs > 0)
            --m_pending;
        deliver(request, list);
    });
}

void MockStorageBackend::scanVolume(const QString &id)
{
    m_scanCalls.append(id);
    const int at = indexOf(id);
    QString status = QStringLiteral("ok");
    if (id.isEmpty()) {
        status = QStringLiteral("invalid");
    } else if (at < 0 || !m_entries.at(at).present) {
        status = QStringLiteral("unknown-volume");
    } else if (!m_entries.at(at).vol.removable || !m_entries.at(at).vol.mounted) {
        status = QStringLiteral("unsupported");
    } else if (!m_scanning.isEmpty() && m_scanning != id) {
        status = QStringLiteral("busy");
    }
    if (status != QLatin1String("ok")) {
        QTimer::singleShot(0, this, [this, id, status] { emit scanStatus(id, status); });
        return;
    }
    const QString state = m_scans.value(id).state;
    // A fresh result (or the scan that already runs) is not walked again; a cancelled one is.
    if (state != QLatin1String("running") && state != QLatin1String("done")) {
        VolumeScan running;
        running.state = QStringLiteral("running");
        m_scans.insert(id, running);
        m_scanning = id;
        if (!m_holdScan)
            QTimer::singleShot(0, this, [this, id] { finishScan(id); });
    }
    publishScan(id, m_delay);
}

void MockStorageBackend::cancelScan(const QString &id)
{
    m_cancelCalls.append(id);
    if (m_scans.value(id).state != QLatin1String("running"))
        return;
    VolumeScan cancelled;
    cancelled.state = QStringLiteral("cancelled");
    cancelled.partial = true;
    m_scans.insert(id, cancelled);
    m_scanning.clear();
    publishScan(id);
}

void MockStorageBackend::holdScan(bool hold)
{
    m_holdScan = hold;
    if (!hold && !m_scanning.isEmpty())
        finishScan(QString(m_scanning)); // a copy: finishing clears m_scanning
}

void MockStorageBackend::finishScan(const QString &id)
{
    if (m_scans.value(id).state != QLatin1String("running"))
        return; // cancelled, or the drive left, meanwhile
    if (m_holdScan)
        return;
    m_scans.insert(id, contentFor(id));
    if (m_scanning == id)
        m_scanning.clear();
    publishScan(id);
}

void MockStorageBackend::dropScans(const QString &drive)
{
    for (const Entry &e : std::as_const(m_entries)) {
        if (e.vol.drive != drive)
            continue;
        m_scans.remove(e.vol.id);
        if (m_scanning == e.vol.id)
            m_scanning.clear();
    }
}

void MockStorageBackend::refreshScanDelayed(const QString &id, int ms)
{
    publishScan(id, ms);
}

VolumeScan MockStorageBackend::contentFor(const QString &id) const
{
    VolumeScan scan;
    scan.state = m_scanFailed ? QStringLiteral("failed") : QStringLiteral("done");
    if (m_scanFailed)
        return scan;
    scan.partial = m_scanPartial;
    auto add = [&scan](const char *key, qint64 bytes, qint64 files) {
        scan.categories.append({QString::fromLatin1(key), bytes, files});
        scan.usedBytes += bytes;
    };
    if (id == QLatin1String("vol-stick")) {
        add("games", 12 * GB, 38);
        add("backups", 2 * GB, 3);
        add("captures", GB + GB / 2, 41);
        add("pictures", 3 * GB / 10, 12);
        scan.otherBytes = 3 * GB + 7 * GB / 10;
    } else if (id == QLatin1String("vol-stick-2")) {
        add("pictures", 4 * GB + GB / 5, 900);
        scan.otherBytes = 300 * 1000 * 1000;
    } else if (id == QLatin1String("vol-card")) {
        scan.otherBytes = 24 * GB;     // photos and videos: nothing RuyaOS knows
    } else {
        scan.otherBytes = GB;
    }
    scan.usedBytes += scan.otherBytes;
    return scan;
}

// A snapshot of the scan as it is now, delivered like a D-Bus reply (a request number, maybe late).
void MockStorageBackend::publishScan(const QString &id, int delayMs)
{
    const quint64 request = beginScanRequest(id);
    const VolumeScan scan = m_scans.value(id);
    if (delayMs > 0)
        ++m_pending;
    QTimer::singleShot(delayMs, this, [this, id, request, scan, delayMs] {
        if (delayMs > 0)
            --m_pending;
        deliverScan(id, request, scan);
    });
}

void MockStorageBackend::publishUsage(int delayMs)
{
    const quint64 request = beginUsageRequest();
    const SystemUsage usage = m_usage;
    if (delayMs > 0)
        ++m_pending;
    QTimer::singleShot(delayMs, this, [this, request, usage, delayMs] {
        if (delayMs > 0)
            --m_pending;
        deliverUsage(request, usage);
    });
}

void MockStorageBackend::answer(const QString &op, const QString &id, const QString &status)
{
    QTimer::singleShot(0, this, [this, op, id, status] { emit finished(op, id, status); });
}
