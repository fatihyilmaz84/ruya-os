#include "MockStorageBackend.h"

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
    publish();
}

void MockStorageBackend::eject(const QString &id)
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
        m_entries[at].present = false;
        publish();
    }
    answer(QStringLiteral("eject"), id, status);
}

void MockStorageBackend::plugStick()
{
    m_plugTimer.stop();
    const int at = indexOf(StickId);
    if (at < 0 || m_entries.at(at).present)
        return;
    m_entries[at].present = true;
    m_entries[at].busy = false;
    // Announced before the list that holds it, like the D-Bus signals.
    QTimer::singleShot(0, this, [this] { emit volumeAdded(StickId); });
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
    m_plugTimer.stop();
    auto entry = [](const char *id, const char *label, const char *fs, qint64 size, qint64 free, bool removable,
                    bool mounted, const char *mountPoint, bool present) {
        Entry e;
        e.vol.id = QString::fromLatin1(id);
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
        entry("vol-internal", "Internal disk", "ext4", 512 * GB, 318 * GB, false, true, "/var", true),
        entry("vol-old", "Old Drive", "unknown", 64 * GB, 0, true, false, "", true),
        entry("vol-stick", "Ruya Stick", "exfat", 32 * GB, 21 * GB + GB / 2, true, true, "/run/media/mock/Ruya Stick", false),
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
void MockStorageBackend::publish()
{
    QList<StorageVolume> list;
    for (const Entry &e : std::as_const(m_entries)) {
        if (e.present)
            list.append(e.vol);
    }
    QTimer::singleShot(0, this, [this, list] { emit volumesListed(list); });
}

void MockStorageBackend::answer(const QString &op, const QString &id, const QString &status)
{
    QTimer::singleShot(0, this, [this, op, id, status] { emit finished(op, id, status); });
}
