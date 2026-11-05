#include "MockStorageBackend.h"

#include <utility>

namespace {
const QString StickId = QStringLiteral("vol-stick");
constexpr qint64 GB = 1000LL * 1000 * 1000;
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

void MockStorageBackend::eject(const QString &id)
{
    ++m_ejectCalls;
    if (m_holdEject) {
        m_heldEjects.append(id);
        return;
    }
    doEject(id);
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

void MockStorageBackend::reset(bool plugStick)
{
    initState();
    publish();
    if (plugStick)
        m_plugTimer.start();
}

// No publishing here: the constructor runs before anybody listens. The stick is absent.
void MockStorageBackend::initState()
{
    m_holdEject = false;
    m_heldEjects.clear();
    m_ejectCalls = 0;
    m_plugTimer.stop();
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
        entry("vol-internal", "drive-internal", "Internal disk", "ext4", 512 * GB, 318 * GB, false, true, "/var", true),
        entry("vol-old", "drive-old", "Old Drive", "unknown", 64 * GB, 0, true, false, "", true),
        entry("vol-stick", "drive-stick", "Ruya Stick", "exfat", 32 * GB, 21 * GB + GB / 2, true, true, "/run/media/mock/Ruya Stick", false),
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

void MockStorageBackend::answer(const QString &op, const QString &id, const QString &status)
{
    QTimer::singleShot(0, this, [this, op, id, status] { emit finished(op, id, status); });
}
