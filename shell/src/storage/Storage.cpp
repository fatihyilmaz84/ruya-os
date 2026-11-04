#include "Storage.h"

#include "DBusStorageBackend.h"
#include "MockStorageBackend.h"

#include <QLocale>

Storage::Storage(std::unique_ptr<StorageBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &StorageBackend::volumeAdded, this, [this](const QString &id) { m_pendingAdded.insert(id); });
    connect(m_backend.get(), &StorageBackend::volumesListed, this, [this](const QList<StorageVolume> &list) {
        QVariantList out;
        for (const StorageVolume &v : list) {
            out.append(QVariantMap{
                {QStringLiteral("id"), v.id},
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
        m_volumes = out;
        emit volumesChanged();
        for (const StorageVolume &v : list) {
            if (m_pendingAdded.remove(v.id))
                emit volumeAdded(v.id, v.label);
        }
    });
    connect(m_backend.get(), &StorageBackend::finished, this, &Storage::finished);
    m_backend->refresh();
}

Storage::~Storage() = default;

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

void Storage::mockReset(bool plugStick)
{
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

void Storage::mockSetBusy(const QString &id, bool busy)
{
    if (auto *mock = qobject_cast<MockStorageBackend *>(m_backend.get()))
        mock->setBusy(id, busy);
}
