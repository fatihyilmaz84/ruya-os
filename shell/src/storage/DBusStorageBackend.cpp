#include "DBusStorageBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Devices1");
const QString Path = QStringLiteral("/org/ruyaos/Devices1");
const QString Interface = QStringLiteral("org.ruyaos.Devices1.Storage");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}

// a{sv}
QVariantMap parseDict(const QDBusArgument &arg)
{
    QVariantMap out;
    arg.beginMap();
    while (!arg.atEnd()) {
        QString key;
        QDBusVariant value;
        arg.beginMapEntry();
        arg >> key >> value;
        arg.endMapEntry();
        out.insert(key, value.variant());
    }
    arg.endMap();
    return out;
}

// aa{sv}
QList<StorageVolume> parseVolumes(const QDBusArgument &arg)
{
    QList<StorageVolume> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        const QVariantMap d = parseDict(arg);
        StorageVolume v;
        v.id = d.value(QStringLiteral("id")).toString();
        v.drive = d.value(QStringLiteral("drive")).toString();
        v.label = d.value(QStringLiteral("label")).toString();
        v.filesystem = d.value(QStringLiteral("filesystem"), v.filesystem).toString();
        v.sizeBytes = d.value(QStringLiteral("size_bytes")).toLongLong();
        v.freeBytes = d.value(QStringLiteral("free_bytes")).toLongLong();
        v.removable = d.value(QStringLiteral("removable")).toBool();
        v.mounted = d.value(QStringLiteral("mounted")).toBool();
        v.mountPoint = d.value(QStringLiteral("mount_point")).toString();
        v.readOnly = d.value(QStringLiteral("read_only")).toBool();
        out.append(v);
    }
    arg.endArray();
    return out;
}
} // namespace

DBusStorageBackend::DBusStorageBackend(QObject *parent)
    : StorageBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("VolumesChanged"), this, SLOT(onVolumesChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("VolumeAdded"), this, SLOT(onVolumeAdded(QString)));
}

void DBusStorageBackend::refresh()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListVolumes"));
    const quint64 request = beginRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Storage ListVolumes failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        deliver(request, parseVolumes(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}

void DBusStorageBackend::eject(const QString &id)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Eject"));
    msg << id;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid())
            qWarning("ruya-shell: Devices1.Storage Eject failed: %s", qPrintable(reply.error().message()));
        emit finished(QStringLiteral("eject"), id, reply.isValid() ? reply.value() : QStringLiteral("failed"));
    });
}

void DBusStorageBackend::onVolumesChanged()
{
    refresh();
}

void DBusStorageBackend::onVolumeAdded(const QString &id)
{
    emit volumeAdded(id); // the service sends VolumeAdded before VolumesChanged
}
