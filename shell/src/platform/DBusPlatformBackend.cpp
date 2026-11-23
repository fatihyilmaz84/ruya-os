#include "DBusPlatformBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Platform1");
const QString Path = QStringLiteral("/org/ruyaos/Platform1");
const QString Interface = QStringLiteral("org.ruyaos.Platform1.Manage");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}

// The status string of a reply, or "failed" for an error or a reply of the wrong shape.
QString statusOf(const QDBusMessage &reply, int arguments)
{
    if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().size() != arguments)
        return QStringLiteral("failed");
    return reply.arguments().constFirst().toString();
}

// a(sb)
QList<CapabilityInfo> parseCapabilities(const QDBusArgument &arg)
{
    QList<CapabilityInfo> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        CapabilityInfo c;
        arg.beginStructure();
        arg >> c.key >> c.defaultAllowed;
        arg.endStructure();
        out.append(c);
    }
    arg.endArray();
    return out;
}

// a(ssb)
QList<PermissionInfo> parsePermissions(const QDBusArgument &arg)
{
    QList<PermissionInfo> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        PermissionInfo p;
        arg.beginStructure();
        arg >> p.appId >> p.capability >> p.allowed;
        arg.endStructure();
        out.append(p);
    }
    arg.endArray();
    return out;
}
} // namespace

DBusPlatformBackend::DBusPlatformBackend(QObject *parent)
    : PlatformBackend(parent)
    , m_bus(chooseBus())
{
}

void DBusPlatformBackend::listCapabilities()
{
    const auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListCapabilities"));
    const quint64 request = beginCapabilitiesRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        const QString status = statusOf(reply, 2);
        if (status != QLatin1String("ok")) {
            deliverCapabilities(request, status, {});
            return;
        }
        deliverCapabilities(request, status, parseCapabilities(reply.arguments().at(1).value<QDBusArgument>()));
    });
}

void DBusPlatformBackend::listPermissions(const QString &profileId)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListPermissions"));
    msg << profileId;
    const quint64 request = beginPermissionsRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, request, profileId](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        const QString status = statusOf(reply, 2);
        if (status != QLatin1String("ok")) {
            deliverPermissions(request, profileId, status, {});
            return;
        }
        deliverPermissions(request, profileId, status,
                           parsePermissions(reply.arguments().at(1).value<QDBusArgument>()));
    });
}

void DBusPlatformBackend::setPermission(const QString &profileId, const QString &appId, const QString &capability,
                                        bool allowed)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("SetPermission"));
    msg << profileId << appId << capability << allowed;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, profileId, appId, capability](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        emit permissionSet(profileId, appId, capability, statusOf(w->reply(), 1));
    });
}
