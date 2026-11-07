#include "DBusUsageBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>
#include <QSharedPointer>

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
QList<QVariantMap> parseDicts(const QDBusArgument &arg)
{
    QList<QVariantMap> out;
    arg.beginArray();
    while (!arg.atEnd())
        out.append(parseDict(arg));
    arg.endArray();
    return out;
}

QVariantMap rowOf(const QVariantMap &d)
{
    return {{QStringLiteral("appId"), d.value(QStringLiteral("app_id")).toString()},
            {QStringLiteral("day"), d.value(QStringLiteral("day")).toString()},
            {QStringLiteral("seconds"), d.value(QStringLiteral("seconds")).toInt()},
            {QStringLiteral("sessions"), d.value(QStringLiteral("sessions")).toInt()},
            {QStringLiteral("longest"), d.value(QStringLiteral("longest")).toInt()},
            {QStringLiteral("first"), d.value(QStringLiteral("first")).toLongLong()},
            {QStringLiteral("last"), d.value(QStringLiteral("last")).toLongLong()}};
}

QVariantMap sessionOf(const QVariantMap &d)
{
    return {{QStringLiteral("appId"), d.value(QStringLiteral("app_id")).toString()},
            {QStringLiteral("appVersion"), d.value(QStringLiteral("app_version")).toString()},
            {QStringLiteral("start"), d.value(QStringLiteral("start")).toLongLong()},
            {QStringLiteral("end"), d.value(QStringLiteral("end")).toLongLong()},
            {QStringLiteral("seconds"), d.value(QStringLiteral("foreground_seconds")).toInt()},
            {QStringLiteral("reason"), d.value(QStringLiteral("exit_reason")).toString()},
            {QStringLiteral("day"), d.value(QStringLiteral("day")).toString()},
            {QStringLiteral("open"), d.value(QStringLiteral("open")).toBool()}};
}

// The two halves of one refresh, until both have answered.
struct Pending
{
    UsageSnapshot snapshot;
    int waiting = 2;
    bool failed = false;
    QString failure;
};
} // namespace

DBusUsageBackend::DBusUsageBackend(QObject *parent)
    : UsageBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] {
        if (!m_lastProfile.isEmpty())
            refresh(m_lastProfile);
    });
    m_bus.connect(Service, Path, Interface, QStringLiteral("UsageChanged"), this, SIGNAL(usageChanged(QString)));
}

void DBusUsageBackend::refresh(const QString &profile)
{
    m_lastProfile = profile;
    const quint64 request = beginRefresh();
    auto pending = QSharedPointer<Pending>::create();
    auto finish = [this, request, profile, pending](const QString &failure) {
        if (!failure.isEmpty() && !pending->failed) {
            pending->failed = true;
            pending->failure = failure;
        }
        if (--pending->waiting > 0)
            return;
        if (pending->failed)
            pending->snapshot = UsageSnapshot{pending->failure, {}, {}, {}};
        deliver(request, profile, pending->snapshot);
    };

    auto totals = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetTotals"));
    totals << profile << QString() << QString();
    auto *tw = new QDBusPendingCallWatcher(m_bus.asyncCall(totals), this);
    connect(tw, &QDBusPendingCallWatcher::finished, this, [pending, finish](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().size() < 3) {
            qWarning("ruya-shell: Session1 GetTotals failed: %s", qPrintable(reply.errorMessage()));
            finish(QStringLiteral("failed"));
            return;
        }
        const QString status = reply.arguments().at(0).toString();
        if (status != QLatin1String("ok")) {
            finish(status);
            return;
        }
        pending->snapshot.today = reply.arguments().at(1).toString();
        const auto rows = parseDicts(reply.arguments().at(2).value<QDBusArgument>());
        for (const QVariantMap &d : rows)
            pending->snapshot.rows.append(rowOf(d));
        finish({});
    });

    auto list = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListSessions"));
    list << profile << qint64(0) << uint(60);
    auto *lw = new QDBusPendingCallWatcher(m_bus.asyncCall(list), this);
    connect(lw, &QDBusPendingCallWatcher::finished, this, [pending, finish](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().size() < 2) {
            qWarning("ruya-shell: Session1 ListSessions failed: %s", qPrintable(reply.errorMessage()));
            finish(QStringLiteral("failed"));
            return;
        }
        const QString status = reply.arguments().at(0).toString();
        if (status != QLatin1String("ok")) {
            finish(status);
            return;
        }
        const auto sessions = parseDicts(reply.arguments().at(1).value<QDBusArgument>());
        for (const QVariantMap &d : sessions)
            pending->snapshot.sessions.append(sessionOf(d));
        finish({});
    });
}

void DBusUsageBackend::clearHistory(const QString &profile)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ClearHistory"));
    msg << profile << QString() << QString();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, profile](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString, uint, uint> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Session1 ClearHistory failed: %s", qPrintable(reply.error().message()));
            emit clearFinished(profile, QStringLiteral("failed"));
            return;
        }
        emit clearFinished(profile, reply.argumentAt<0>());
    });
}

void DBusUsageBackend::reportPresence(const QString &profile, const QString &instance, const QString &attention)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ReportPresence"));
    msg << profile << instance << attention;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        // Quiet after the first complaint: this is called every 20 s.
        if (!reply.isValid() && !m_presenceWarned) {
            m_presenceWarned = true;
            qWarning("ruya-shell: Session1 ReportPresence failed: %s", qPrintable(reply.error().message()));
        }
    });
}
