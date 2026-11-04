#include "DBusBatteryBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Devices1");
const QString Path = QStringLiteral("/org/ruyaos/Devices1");
const QString Interface = QStringLiteral("org.ruyaos.Devices1.Batteries");

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
QList<ControllerBattery> parseBatteries(const QDBusArgument &arg)
{
    QList<ControllerBattery> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        const QVariantMap d = parseDict(arg);
        ControllerBattery c;
        c.id = d.value(QStringLiteral("id")).toString();
        c.name = d.value(QStringLiteral("name")).toString();
        c.percent = qBound(0, int(d.value(QStringLiteral("percent")).toUInt()), 100);
        c.state = d.value(QStringLiteral("state"), c.state).toString();
        out.append(c);
    }
    arg.endArray();
    return out;
}
} // namespace

DBusBatteryBackend::DBusBatteryBackend(QObject *parent)
    : BatteryBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("BatteriesChanged"), this, SLOT(onBatteriesChanged()));
}

void DBusBatteryBackend::refresh()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListBatteries"));
    const quint64 request = beginRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Batteries ListBatteries failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        deliver(request, parseBatteries(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}
