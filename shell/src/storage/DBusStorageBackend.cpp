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

// The dictionary of GetVolumeScan; `categories` is an aa{sv} inside the variant.
VolumeScan parseScan(const QVariantMap &d)
{
    VolumeScan scan;
    scan.state = d.value(QStringLiteral("state"), scan.state).toString();
    scan.partial = d.value(QStringLiteral("partial")).toBool();
    scan.usedBytes = d.value(QStringLiteral("used_bytes")).toLongLong();
    scan.otherBytes = d.value(QStringLiteral("other_bytes")).toLongLong();
    const QVariant categories = d.value(QStringLiteral("categories"));
    if (categories.canConvert<QDBusArgument>()) {
        const QDBusArgument arg = categories.value<QDBusArgument>();
        arg.beginArray();
        while (!arg.atEnd()) {
            const QVariantMap c = parseDict(arg);
            DriveCategory category;
            category.key = c.value(QStringLiteral("key")).toString();
            category.bytes = c.value(QStringLiteral("bytes")).toLongLong();
            category.files = c.value(QStringLiteral("files")).toLongLong();
            scan.categories.append(category);
        }
        arg.endArray();
    }
    return scan;
}

qint64 number(const QVariantMap &d, const char *key)
{
    const QVariant v = d.value(QString::fromLatin1(key));
    return v.isValid() ? v.toLongLong() : -1;
}
} // namespace

DBusStorageBackend::DBusStorageBackend(QObject *parent)
    : StorageBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] {
        refresh();
        refreshUsage();
    });
    m_bus.connect(Service, Path, Interface, QStringLiteral("VolumesChanged"), this, SLOT(onVolumesChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("VolumeAdded"), this, SLOT(onVolumeAdded(QString)));
    m_bus.connect(Service, Path, Interface, QStringLiteral("SystemUsageChanged"), this, SLOT(onUsageChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("VolumeScanChanged"), this, SLOT(onScanChanged(QString)));
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

void DBusStorageBackend::refreshUsage()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetSystemUsage"));
    const quint64 request = beginUsageRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Storage GetSystemUsage failed: %s", qPrintable(reply.errorMessage()));
            acceptUsage(request); // an outcome too: an older reply must not land after it
            return;
        }
        const QVariantMap d = parseDict(reply.arguments().constFirst().value<QDBusArgument>());
        SystemUsage usage;
        usage.totalBytes = number(d, "total_bytes");
        usage.freeBytes = number(d, "free_bytes");
        usage.appsBytes = number(d, "apps_bytes");
        usage.dataBytes = number(d, "data_bytes");
        usage.systemBytes = number(d, "system_bytes");
        deliverUsage(request, usage);
    });
}

void DBusStorageBackend::scanVolume(const QString &id)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ScanVolume"));
    msg << id;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        const bool ok = reply.type() == QDBusMessage::ReplyMessage && !reply.arguments().isEmpty();
        if (!ok)
            qWarning("ruya-shell: Devices1.Storage ScanVolume failed: %s", qPrintable(reply.errorMessage()));
        const QString status = ok ? reply.arguments().constFirst().toString() : QStringLiteral("failed");
        if (status == QLatin1String("ok"))
            readScan(id); // running, or a cached result
        else
            emit scanStatus(id, status);
    });
}

void DBusStorageBackend::cancelScan(const QString &id)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("CancelScan"));
    msg << id;
    m_bus.asyncCall(msg); // nothing to wait for: VolumeScanChanged tells when it stopped
}

void DBusStorageBackend::readScan(const QString &id)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetVolumeScan"));
    msg << id;
    const quint64 request = beginScanRequest(id);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Storage GetVolumeScan failed: %s", qPrintable(reply.errorMessage()));
            acceptScan(id, request); // an outcome too: an older reply must not land after it
            return;
        }
        deliverScan(id, request, parseScan(parseDict(reply.arguments().constFirst().value<QDBusArgument>())));
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

void DBusStorageBackend::saveReport(const QString &id, const QMap<QString, QString> &files)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("SaveReport"));
    // a{ss}
    QDBusArgument map;
    map.beginMap(QMetaType::fromType<QString>(), QMetaType::fromType<QString>());
    for (auto it = files.cbegin(); it != files.cend(); ++it) {
        map.beginMapEntry();
        map << it.key() << it.value();
        map.endMapEntry();
    }
    map.endMap();
    msg << id << QVariant::fromValue(map);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        const bool ok = reply.type() == QDBusMessage::ReplyMessage && !reply.arguments().isEmpty();
        if (!ok)
            qWarning("ruya-shell: Devices1.Storage SaveReport failed: %s", qPrintable(reply.errorMessage()));
        emit finished(QStringLiteral("saveReport"), id,
                      ok ? reply.arguments().constFirst().toString() : QStringLiteral("failed"));
    });
}

void DBusStorageBackend::listFiles(const QString &id, const QString &suffix)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListFiles"));
    msg << id << suffix;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id, suffix](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().size() < 2) {
            qWarning("ruya-shell: Devices1.Storage ListFiles failed: %s", qPrintable(reply.errorMessage()));
            emit filesListed(id, suffix, QStringLiteral("failed"), {});
            return;
        }
        // aa{sv}: { name s, size_bytes x, modified x }
        QVariantList rows;
        const QDBusArgument arg = reply.arguments().at(1).value<QDBusArgument>();
        arg.beginArray();
        while (!arg.atEnd()) {
            QVariantMap d;
            arg.beginMap();
            while (!arg.atEnd()) {
                QString key;
                QDBusVariant value;
                arg.beginMapEntry();
                arg >> key >> value;
                arg.endMapEntry();
                d.insert(key, value.variant());
            }
            arg.endMap();
            rows.append(QVariantMap{
                {QStringLiteral("name"), d.value(QStringLiteral("name")).toString()},
                {QStringLiteral("sizeBytes"), d.value(QStringLiteral("size_bytes")).toLongLong()},
                {QStringLiteral("modified"), d.value(QStringLiteral("modified")).toLongLong()},
            });
        }
        arg.endArray();
        emit filesListed(id, suffix, reply.arguments().constFirst().toString(), rows);
    });
}

void DBusStorageBackend::readFile(const QString &id, const QString &name, quint32 maxBytes)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ReadFile"));
    msg << id << name << maxBytes;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id, name](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().size() < 2) {
            qWarning("ruya-shell: Devices1.Storage ReadFile failed: %s", qPrintable(reply.errorMessage()));
            emit fileRead(id, name, QStringLiteral("failed"), QString());
            return;
        }
        emit fileRead(id, name, reply.arguments().at(0).toString(), reply.arguments().at(1).toString());
    });
}

void DBusStorageBackend::onVolumesChanged()
{
    refresh();
}

void DBusStorageBackend::onUsageChanged()
{
    refreshUsage();
}

void DBusStorageBackend::onScanChanged(const QString &id)
{
    readScan(id);
}

void DBusStorageBackend::onVolumeAdded(const QString &id)
{
    emit volumeAdded(id); // the service sends VolumeAdded before VolumesChanged
}
