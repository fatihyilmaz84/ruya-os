#include "DBusInputBackend.h"

#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Input1");
const QString Path = QStringLiteral("/org/ruyaos/Input1");
const QString Interface = QStringLiteral("org.ruyaos.Input1");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}
} // namespace

DBusInputBackend::DBusInputBackend(QObject *parent)
    : InputBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForOwnerChange, this)
{
    // An owner change straight from one owner to the next (no gap) is a new service too.
    connect(&m_watcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &, const QString &newOwner) {
                m_ownerSeen = true;
                setServiceOwned(!newOwner.isEmpty());
                if (!newOwner.isEmpty())
                    emit serviceAppeared();
            });
    // Who owns the name now, asked without blocking; a change that arrives first wins.
    if (auto *busInterface = m_bus.interface()) {
        auto *asked = new QDBusPendingCallWatcher(busInterface->asyncCall(QStringLiteral("NameHasOwner"), Service), this);
        connect(asked, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            QDBusPendingReply<bool> reply = *w;
            if (reply.isValid() && !m_ownerSeen)
                setServiceOwned(reply.value());
        });
    }
}

void DBusInputBackend::setRoute(const QString &route, const QString &instance, const QString &appId,
                                const QString &profile)
{
    const quint64 request = beginRoute();
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("SetRoute"));
    msg << route << instance << appId << profile;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request, route](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Input1 SetRoute %s failed: %s", qPrintable(route), qPrintable(reply.error().message()));
            deliverRoute(request, QStringLiteral("failed"));
            return;
        }
        deliverRoute(request, reply.argumentAt<0>());
    });
}
