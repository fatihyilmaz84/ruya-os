#include "DBusBluetoothBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Devices1");
const QString Path = QStringLiteral("/org/ruyaos/Devices1");
const QString Interface = QStringLiteral("org.ruyaos.Devices1.Bluetooth");
const QString PropertiesInterface = QStringLiteral("org.freedesktop.DBus.Properties");

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
QList<BtDevice> parseDevices(const QDBusArgument &arg)
{
    QList<BtDevice> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        const QVariantMap d = parseDict(arg);
        BtDevice dev;
        dev.id = d.value(QStringLiteral("id")).toString();
        dev.name = d.value(QStringLiteral("name")).toString();
        dev.kind = d.value(QStringLiteral("kind"), dev.kind).toString();
        dev.paired = d.value(QStringLiteral("paired")).toBool();
        dev.connected = d.value(QStringLiteral("connected")).toBool();
        dev.trusted = d.value(QStringLiteral("trusted")).toBool();
        dev.battery = d.value(QStringLiteral("battery"), -1).toInt();
        out.append(dev);
    }
    arg.endArray();
    return out;
}
} // namespace

DBusBluetoothBackend::DBusBluetoothBackend(QObject *parent)
    : BluetoothBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("DevicesChanged"), this, SLOT(onDevicesChanged()));
    m_bus.connect(Service, Path, PropertiesInterface, QStringLiteral("PropertiesChanged"), this,
                  SLOT(onPropertiesChanged(QString, QVariantMap, QStringList)));
}

void DBusBluetoothBackend::refresh()
{
    refreshState();
    refreshDevices();
}

void DBusBluetoothBackend::refreshState()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, PropertiesInterface, QStringLiteral("GetAll"));
    msg << Interface;
    const quint64 request = beginStateRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Bluetooth GetAll failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        const QVariantMap props = parseDict(reply.arguments().constFirst().value<QDBusArgument>());
        deliverState(request, props.value(QStringLiteral("Powered")).toBool(),
                     props.value(QStringLiteral("Discovering")).toBool());
    });
}

void DBusBluetoothBackend::refreshDevices()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListDevices"));
    const quint64 request = beginDevicesRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Bluetooth ListDevices failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        deliverDevices(request, parseDevices(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}

void DBusBluetoothBackend::setPowered(bool on)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, PropertiesInterface, QStringLiteral("Set"));
    msg << Interface << QStringLiteral("Powered") << QVariant::fromValue(QDBusVariant(on));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        const bool ok = reply.type() == QDBusMessage::ReplyMessage;
        if (!ok)
            qWarning("ruya-shell: Devices1.Bluetooth Set Powered failed: %s", qPrintable(reply.errorMessage()));
        emit finished(QStringLiteral("power"), QString(), ok ? QStringLiteral("ok") : QStringLiteral("failed"));
    });
}

void DBusBluetoothBackend::startCommand(const QString &method, const QString &op, const QString &id,
                                        const QVariantList &args)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg.setArguments(args);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, method, op, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid())
            qWarning("ruya-shell: Devices1.Bluetooth %s failed: %s", qPrintable(method),
                     qPrintable(reply.error().message()));
        emit finished(op, id, reply.isValid() ? reply.value() : QStringLiteral("failed"));
    });
}

void DBusBluetoothBackend::startScan()
{
    startCommand(QStringLiteral("StartScan"), QStringLiteral("scan"), QString(), {});
}

void DBusBluetoothBackend::stopScan()
{
    startCommand(QStringLiteral("StopScan"), QStringLiteral("scan"), QString(), {});
}

void DBusBluetoothBackend::pair(const QString &id)
{
    startCommand(QStringLiteral("Pair"), QStringLiteral("pair"), id, {id});
}

void DBusBluetoothBackend::forget(const QString &id)
{
    startCommand(QStringLiteral("Forget"), QStringLiteral("forget"), id, {id});
}

void DBusBluetoothBackend::connectDevice(const QString &id)
{
    startCommand(QStringLiteral("Connect"), QStringLiteral("connect"), id, {id});
}

void DBusBluetoothBackend::disconnectDevice(const QString &id)
{
    startCommand(QStringLiteral("Disconnect"), QStringLiteral("disconnect"), id, {id});
}

void DBusBluetoothBackend::onDevicesChanged()
{
    refreshDevices();
}

void DBusBluetoothBackend::onPropertiesChanged(const QString &interface, const QVariantMap &, const QStringList &)
{
    if (interface == Interface)
        refresh(); // Powered also empties or refills the list
}
