#include "DBusSessionBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Session1");
const QString Path = QStringLiteral("/org/ruyaos/Session1");
const QString Interface = QStringLiteral("org.ruyaos.Session1");

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
QList<RunningApp> parseRunning(const QDBusArgument &arg)
{
    QList<RunningApp> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        const QVariantMap d = parseDict(arg);
        RunningApp r;
        r.instance = d.value(QStringLiteral("instance")).toString();
        r.appId = d.value(QStringLiteral("app_id")).toString();
        r.profile = d.value(QStringLiteral("profile")).toString();
        r.started = d.value(QStringLiteral("started")).toLongLong();
        r.state = d.value(QStringLiteral("state"), r.state).toString();
        out.append(r);
    }
    arg.endArray();
    return out;
}
} // namespace

DBusSessionBackend::DBusSessionBackend(QObject *parent)
    : SessionBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("AppStarted"), this, SIGNAL(appStarted(QString, QString)));
    m_bus.connect(Service, Path, Interface, QStringLiteral("AppExited"), this,
                  SIGNAL(appExited(QString, QString, int, QString)));
}

void DBusSessionBackend::refresh()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListRunning"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Session1 ListRunning failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        emit runningListed(parseRunning(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}

void DBusSessionBackend::launch(const QString &appId, const QString &profile)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Launch"));
    msg << appId << profile;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, appId, profile](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString, QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Session1 Launch %s failed: %s", qPrintable(appId), qPrintable(reply.error().message()));
            emit launchFinished(appId, profile, QStringLiteral("failed"), {});
            return;
        }
        emit launchFinished(appId, profile, reply.argumentAt<0>(), reply.argumentAt<1>());
    });
}

void DBusSessionBackend::stop(const QString &instance)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Stop"));
    msg << instance;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, instance](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Session1 Stop %s failed: %s", qPrintable(instance), qPrintable(reply.error().message()));
            emit stopFinished(instance, QStringLiteral("failed"));
            return;
        }
        emit stopFinished(instance, reply.argumentAt<0>());
    });
}
