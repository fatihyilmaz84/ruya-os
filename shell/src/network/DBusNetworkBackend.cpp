#include "DBusNetworkBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Devices1");
const QString Path = QStringLiteral("/org/ruyaos/Devices1");
const QString Interface = QStringLiteral("org.ruyaos.Devices1.Network");
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
QList<WifiInfo> parseNetworks(const QDBusArgument &arg)
{
    QList<WifiInfo> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        const QVariantMap d = parseDict(arg);
        WifiInfo n;
        n.id = d.value(QStringLiteral("id")).toString();
        n.ssid = d.value(QStringLiteral("ssid")).toString();
        n.signal = int(d.value(QStringLiteral("signal")).toUInt());
        n.security = d.value(QStringLiteral("security"), n.security).toString();
        n.known = d.value(QStringLiteral("known")).toBool();
        n.active = d.value(QStringLiteral("active")).toBool();
        out.append(n);
    }
    arg.endArray();
    return out;
}
} // namespace

DBusNetworkBackend::DBusNetworkBackend(QObject *parent)
    : NetworkBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("NetworksChanged"), this, SLOT(onNetworksChanged()));
    m_bus.connect(Service, Path, PropertiesInterface, QStringLiteral("PropertiesChanged"), this,
                  SLOT(onPropertiesChanged(QString, QVariantMap, QStringList)));
}

void DBusNetworkBackend::refresh()
{
    refreshState();
    refreshNetworks();
}

void DBusNetworkBackend::refreshState()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, PropertiesInterface, QStringLiteral("GetAll"));
    msg << Interface;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Network GetAll failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        const QVariantMap props = parseDict(reply.arguments().constFirst().value<QDBusArgument>());
        QVariantMap primary;
        const QVariant raw = props.value(QStringLiteral("Primary"));
        if (raw.canConvert<QDBusArgument>())
            primary = parseDict(raw.value<QDBusArgument>());
        emit stateChanged(props.value(QStringLiteral("State"), QStringLiteral("disconnected")).toString(), primary);
    });
}

void DBusNetworkBackend::refreshNetworks()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListWifi"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Network ListWifi failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        emit networksListed(parseNetworks(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}

void DBusNetworkBackend::scan()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Scan"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid())
            qWarning("ruya-shell: Devices1.Network Scan failed: %s", qPrintable(reply.error().message()));
    });
}

// The arguments (the password) never go into a log line.
void DBusNetworkBackend::startCommand(const QString &method, const QString &id, const QVariantList &args,
                                      bool isConnect)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg.setArguments(args);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, method, id, isConnect](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid())
            qWarning("ruya-shell: Devices1.Network %s failed: %s", qPrintable(method),
                     qPrintable(reply.error().message()));
        const QString status = reply.isValid() ? reply.value() : QStringLiteral("failed");
        if (isConnect)
            emit connectFinished(id, status);
        else
            emit forgetFinished(id, status);
    });
}

void DBusNetworkBackend::connectWifi(const QString &id, const QString &password)
{
    startCommand(QStringLiteral("Connect"), id, {id, password}, true);
}

void DBusNetworkBackend::forget(const QString &id)
{
    startCommand(QStringLiteral("Forget"), id, {id}, false);
}

void DBusNetworkBackend::onNetworksChanged()
{
    refreshNetworks();
}

void DBusNetworkBackend::onPropertiesChanged(const QString &interface, const QVariantMap &, const QStringList &)
{
    if (interface == Interface)
        refreshState();
}
