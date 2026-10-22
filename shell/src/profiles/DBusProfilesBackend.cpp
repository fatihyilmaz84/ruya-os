#include "DBusProfilesBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Profiles1");
const QString Path = QStringLiteral("/org/ruyaos/Profiles1");
const QString Interface = QStringLiteral("org.ruyaos.Profiles1");
const QString PropertiesInterface = QStringLiteral("org.freedesktop.DBus.Properties");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}

QList<ProfileInfo> parseProfiles(const QDBusArgument &arg)
{
    QList<ProfileInfo> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        ProfileInfo p;
        arg.beginStructure();
        arg >> p.id >> p.name >> p.avatar >> p.role >> p.hasPin;
        arg.endStructure();
        out.append(p);
    }
    arg.endArray();
    return out;
}
} // namespace

DBusProfilesBackend::DBusProfilesBackend(QObject *parent)
    : ProfilesBackend(parent)
    , m_bus(chooseBus())
{
    m_bus.connect(Service, Path, Interface, QStringLiteral("ProfilesChanged"), this, SLOT(onProfilesChanged()));
    m_bus.connect(Service, Path, PropertiesInterface, QStringLiteral("PropertiesChanged"), this,
                  SLOT(onPropertiesChanged(QString, QVariantMap, QStringList)));
}

void DBusProfilesBackend::refresh()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListProfiles"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Profiles1.ListProfiles failed: %s", qPrintable(reply.errorMessage()));
            emit availabilityChanged(false);
            return;
        }
        emit availabilityChanged(true);
        emit listed(parseProfiles(reply.arguments().constFirst().value<QDBusArgument>()));
        fetchActive();
    });
}

void DBusProfilesBackend::fetchActive()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, PropertiesInterface, QStringLiteral("Get"));
    msg << Interface << QStringLiteral("ActiveProfile");
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QDBusVariant> reply = *w;
        if (reply.isValid())
            emit activeChanged(reply.value().variant().toString());
    });
}

void DBusProfilesBackend::switchTo(const QString &id, const QString &pin)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("SwitchTo"));
    msg << id << pin;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString, uint, uint> reply = *w;
        if (!reply.isValid()) {
            emit switchFinished(id, QStringLiteral("failed"), 0, 0);
            return;
        }
        // ActiveProfile change arrives via PropertiesChanged.
        emit switchFinished(id, reply.argumentAt<0>(), int(reply.argumentAt<1>()), int(reply.argumentAt<2>()));
    });
}

void DBusProfilesBackend::lock()
{
    m_bus.asyncCall(QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Lock")));
}

void DBusProfilesBackend::probeAttempts(const QString &id, std::function<void(int, int)> done)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("SwitchTo"));
    msg << id << QString();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [done](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString, uint, uint> reply = *w;
        if (reply.isValid())
            done(int(reply.argumentAt<1>()), int(reply.argumentAt<2>()));
        else
            done(0, 0);
    });
}

void DBusProfilesBackend::createProfile(const QString &adminId, const QString &adminPin, const QString &name,
                                        const QString &role, const QString &pin)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("CreateProfile"));
    msg << adminId << adminPin << name << role << pin;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, adminId](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString, QString> reply = *w;
        if (!reply.isValid()) {
            emit createFinished(QStringLiteral("failed"), {}, 0, 0);
            return;
        }
        const QString status = reply.argumentAt<0>();
        const QString id = reply.argumentAt<1>();
        if (status == QLatin1String("wrong-pin") || status == QLatin1String("locked-out")) {
            probeAttempts(adminId, [this, status](int left, int retry) { emit createFinished(status, {}, left, retry); });
            return;
        }
        emit createFinished(status, id, 0, 0);   // the list refreshes via ProfilesChanged
    });
}

void DBusProfilesBackend::setPin(const QString &id, const QString &oldPin, const QString &newPin)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("SetPin"));
    msg << id << oldPin << newPin;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid()) {
            emit setPinFinished(id, QStringLiteral("failed"), 0, 0);
            return;
        }
        const QString status = reply.argumentAt<0>();
        if (status == QLatin1String("wrong-pin") || status == QLatin1String("locked-out")) {
            probeAttempts(id, [this, id, status](int left, int retry) { emit setPinFinished(id, status, left, retry); });
            return;
        }
        emit setPinFinished(id, status, 0, 0);
        if (status == QLatin1String("ok"))
            refresh();                            // hasPin changed
    });
}

void DBusProfilesBackend::onProfilesChanged()
{
    refresh();
}

void DBusProfilesBackend::onPropertiesChanged(const QString &interface, const QVariantMap &changed,
                                              const QStringList &invalidated)
{
    if (interface != Interface)
        return;
    if (changed.contains(QStringLiteral("ActiveProfile")))
        emit activeChanged(changed.value(QStringLiteral("ActiveProfile")).toString());
    else if (invalidated.contains(QStringLiteral("ActiveProfile")))
        fetchActive();
}
