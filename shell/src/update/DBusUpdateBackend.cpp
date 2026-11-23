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
    s.autoRestart = d.value(QStringLiteral("auto_restart"), s.autoRestart).toBool();
    s.lastCheck = d.value(QStringLiteral("last_check")).toLongLong();
    s.restartAt = d.value(QStringLiteral("restart_at")).toLongLong();
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
    m_bus.connect(Service, Path, Interface, QStringLiteral("JobChanged"), this,
                  SLOT(onJobChanged(QDBusMessage)));
}

void DBusUpdateBackend::refresh()
{
    refreshStatus();
    refreshJob();
}

// Calls a Get method of Update1 whose reply holds an a{sv} at argument `index`: `deliver` gets it,
// or `failed` runs (a failure is an outcome too: an older reply after it is stale).
void DBusUpdateBackend::getRecord(const QString &method, int index,
                                  const std::function<void(const QVariantMap &)> &deliver,
                                  const std::function<void()> &failed)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [method, index, deliver, failed](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage message = w->reply();
        if (message.type() != QDBusMessage::ReplyMessage || message.arguments().size() <= index) {
            qWarning("ruya-shell: Update1 %s failed: %s", qPrintable(method), qPrintable(w->error().message()));
            failed();
            return;
        }
        deliver(parseDict(message.arguments().at(index).value<QDBusArgument>()));
    });
}

void DBusUpdateBackend::refreshStatus()
{
    const quint64 request = beginStatusRequest();
    getRecord(
        QStringLiteral("GetStatus"), 0,
        [this, request](const QVariantMap &d) { deliverStatus(request, toStatus(d)); },
        [this, request] { acceptStatus(request); });
}

void DBusUpdateBackend::refreshJob()
{
    // GetDownloadJob answers (status, job).
    const quint64 request = beginJobRequest();
    getRecord(
        QStringLiteral("GetDownloadJob"), 1, [this, request](const QVariantMap &d) { deliverJob(request, d); },
        [this, request] { acceptJob(request); });
}

void DBusUpdateBackend::onJobChanged(const QDBusMessage &message)
{
    if (message.arguments().isEmpty())
        return;
    deliverJob(beginJobRequest(), parseDict(message.arguments().at(0).value<QDBusArgument>()));
}

void DBusUpdateBackend::onStatusChanged()
{
    refreshStatus(); // the job comes with its own signal
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

void DBusUpdateBackend::pauseDownload()
{
    call(QStringLiteral("PauseDownload"), QStringLiteral("pauseDownload"));
}

void DBusUpdateBackend::resumeDownload()
{
    call(QStringLiteral("ResumeDownload"), QStringLiteral("resumeDownload"));
}

void DBusUpdateBackend::cancelDownload()
{
    call(QStringLiteral("CancelDownload"), QStringLiteral("cancelDownload"));
}

void DBusUpdateBackend::rollback()
{
    call(QStringLiteral("Rollback"), QStringLiteral("rollback"));
}

void DBusUpdateBackend::setChannel(const QString &channel)
{
    call(QStringLiteral("SetChannel"), QStringLiteral("setChannel"), {channel});
}

void DBusUpdateBackend::setAutoRestart(bool enabled)
{
    call(QStringLiteral("SetAutoRestart"), QStringLiteral("setAutoRestart"), {enabled});
}

void DBusUpdateBackend::reportActivity(bool appRunning)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ReportActivity"));
    msg.setArguments({appRunning});
    m_bus.asyncCall(msg);
}
