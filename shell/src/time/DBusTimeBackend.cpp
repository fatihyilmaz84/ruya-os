#include "DBusTimeBackend.h"

#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Devices1");
const QString Path = QStringLiteral("/org/ruyaos/Devices1");
const QString Interface = QStringLiteral("org.ruyaos.Devices1.Time");
const QString Properties = QStringLiteral("org.freedesktop.DBus.Properties");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}
} // namespace

DBusTimeBackend::DBusTimeBackend(QObject *parent)
    : TimeBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("TimezoneChanged"), this, SLOT(onChanged()));
    // NtpSynchronised changes as a property.
    m_bus.connect(Service, Path, Properties, QStringLiteral("PropertiesChanged"), this,
                  SLOT(onPropertiesChanged(QString,QVariantMap,QStringList)));
}

void DBusTimeBackend::onPropertiesChanged(const QString &interface, const QVariantMap &, const QStringList &)
{
    if (interface == Interface)
        refresh();
}

void DBusTimeBackend::refresh()
{
    const quint64 request = beginStateRequest();
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetTimezone"));
    auto *zone = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(zone, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Devices1.Time GetTimezone failed: %s", qPrintable(reply.error().message()));
            acceptState(request); // a failure is an outcome too: an older reply after it is stale
            return;
        }
        const QString name = reply.value();
        auto get = QDBusMessage::createMethodCall(Service, Path, Properties, QStringLiteral("Get"));
        get.setArguments({Interface, QStringLiteral("NtpSynchronised")});
        auto *ntp = new QDBusPendingCallWatcher(m_bus.asyncCall(get), this);
        connect(ntp, &QDBusPendingCallWatcher::finished, this, [this, request, name](QDBusPendingCallWatcher *n) {
            n->deleteLater();
            const QDBusPendingReply<QDBusVariant> value = *n;
            // A clock we cannot ask about counts as not synchronised, not as an error.
            const bool synchronised = value.isValid() && value.value().variant().toBool();
            deliverState(request, name, synchronised);
        });
    });
}

void DBusTimeBackend::loadZones()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListTimezones"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<QStringList> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Devices1.Time ListTimezones failed: %s", qPrintable(reply.error().message()));
            return;
        }
        emit zonesListed(reply.value());
    });
}

void DBusTimeBackend::setTimezone(const QString &name)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("SetTimezone"));
    msg.setArguments({name});
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, name](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<QString> reply = *w;
        const QString status = reply.isValid() ? reply.value() : QStringLiteral("failed");
        if (status == QLatin1String("ok"))
            deliverZoneSet(name);
        emit setTimezoneFinished(name, status);
    });
}
