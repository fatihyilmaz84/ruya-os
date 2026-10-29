#include "DBusUpdateBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Update1");
const QString Path = QStringLiteral("/org/ruyaos/Update1");
const QString Interface = QStringLiteral("org.ruyaos.Update1");

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

UpdateStatus toStatus(const QVariantMap &d)
{
    UpdateStatus s;
    s.state = d.value(QStringLiteral("state"), s.state).toString();
    s.current = d.value(QStringLiteral("current")).toString();
    s.available = d.value(QStringLiteral("available")).toString();
    s.staged = d.value(QStringLiteral("staged")).toString();
    s.channel = d.value(QStringLiteral("channel"), s.channel).toString();
    s.lastCheck = d.value(QStringLiteral("last_check")).toLongLong();
    s.progress = d.value(QStringLiteral("progress")).toInt();
    s.rollbackAvailable = d.value(QStringLiteral("rollback_available")).toBool();
    s.error = d.value(QStringLiteral("error")).toString();
    return s;
}
} // namespace

DBusUpdateBackend::DBusUpdateBackend(QObject *parent)
    : UpdateBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("StatusChanged"), this, SLOT(onStatusChanged()));
}

void DBusUpdateBackend::refresh()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetStatus"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage message = w->reply();
        if (message.type() != QDBusMessage::ReplyMessage || message.arguments().isEmpty()) {
            qWarning("ruya-shell: Update1 GetStatus failed: %s", qPrintable(w->error().message()));
            return;
        }
        const QDBusArgument arg = message.arguments().at(0).value<QDBusArgument>();
        emit statusChanged(toStatus(parseDict(arg)));
    });
}

void DBusUpdateBackend::onStatusChanged()
{
    refresh();
}

void DBusUpdateBackend::call(const QString &method, const QString &reportAs, const QVariantList &args)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg.setArguments(args);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, reportAs](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<QString> reply = *w;
        emit requestFinished(reportAs, reply.isValid() ? reply.value() : QStringLiteral("failed"));
    });
}

void DBusUpdateBackend::check()
{
    call(QStringLiteral("Check"), QStringLiteral("check"));
}

void DBusUpdateBackend::download()
{
    call(QStringLiteral("Download"), QStringLiteral("download"));
}

void DBusUpdateBackend::rollback()
{
    call(QStringLiteral("Rollback"), QStringLiteral("rollback"));
}

void DBusUpdateBackend::setChannel(const QString &channel)
{
    call(QStringLiteral("SetChannel"), QStringLiteral("setChannel"), {channel});
}
