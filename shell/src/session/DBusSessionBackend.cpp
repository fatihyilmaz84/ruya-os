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
        r.frozen = d.value(QStringLiteral("frozen"), false).toBool();
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
    m_bus.connect(Service, Path, Interface, QStringLiteral("FrozenChanged"), this, SIGNAL(frozenChanged(QString, bool)));
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

void DBusSessionBackend::freeze(const QString &instance)
{
    freezer(QStringLiteral("Freeze"), instance);
}

void DBusSessionBackend::thaw(const QString &instance)
{
    freezer(QStringLiteral("Thaw"), instance);
}

void DBusSessionBackend::freezer(const QString &method, const QString &instance)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg << instance;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    const bool freezing = method == QLatin1String("Freeze");
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, method, instance, freezing](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        QString status;
        if (reply.isValid()) {
            status = reply.argumentAt<0>();
        } else {
            qWarning("ruya-shell: Session1 %s %s failed: %s", qPrintable(method), qPrintable(instance),
                     qPrintable(reply.error().message()));
            status = QStringLiteral("failed");
        }
        if (freezing)
            emit freezeFinished(instance, status);
        else
            emit thawFinished(instance, status);
    });
}

void DBusSessionBackend::instanceOfPid(int pid)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("InstanceOfPid"));
    msg << static_cast<uint>(pid > 0 ? pid : 0);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, pid](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString, QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Session1 InstanceOfPid %d failed: %s", pid, qPrintable(reply.error().message()));
            emit instanceOfPidFinished(pid, QStringLiteral("failed"), {});
            return;
        }
        emit instanceOfPidFinished(pid, reply.argumentAt<0>(), reply.argumentAt<1>());
    });
}
