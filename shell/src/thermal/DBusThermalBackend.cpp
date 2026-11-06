#include "DBusThermalBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Devices1");
const QString Path = QStringLiteral("/org/ruyaos/Devices1");
const QString Interface = QStringLiteral("org.ruyaos.Devices1.Thermal");

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
QList<ThermalSensor> parseSensors(const QDBusArgument &arg)
{
    QList<ThermalSensor> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        const QVariantMap d = parseDict(arg);
        ThermalSensor s;
        s.id = d.value(QStringLiteral("id")).toString();
        s.label = d.value(QStringLiteral("label")).toString();
        s.cls = d.value(QStringLiteral("class")).toString();
        s.value = d.value(QStringLiteral("value")).toDouble();
        s.level = d.value(QStringLiteral("level"), s.level).toString();
        s.maxSeen = d.value(QStringLiteral("max_seen")).toDouble();
        out.append(s);
    }
    arg.endArray();
    return out;
}
} // namespace

DBusThermalBackend::DBusThermalBackend(QObject *parent)
    : ThermalBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("SensorsChanged"), this, SLOT(onChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("LevelChanged"), this, SLOT(onChanged()));
}

void DBusThermalBackend::refresh()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListSensors"));
    const quint64 request = beginRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Thermal ListSensors failed: %s", qPrintable(reply.errorMessage()));
            acceptFailure(request);
            return;
        }
        deliver(request, parseSensors(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}
