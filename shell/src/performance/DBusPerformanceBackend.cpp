#include "DBusPerformanceBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Devices1");
const QString Path = QStringLiteral("/org/ruyaos/Devices1");
const QString Interface = QStringLiteral("org.ruyaos.Devices1.System");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}

// a{s(sd)}: metric -> (state, value).
QVariantMap parseMetrics(const QDBusArgument &arg)
{
    QVariantMap out;
    arg.beginMap();
    while (!arg.atEnd()) {
        QString name;
        QString state;
        double value = 0;
        arg.beginMapEntry();
        arg >> name;
        arg.beginStructure();
        arg >> state >> value;
        arg.endStructure();
        arg.endMapEntry();
        out.insert(name, QVariantMap { { QStringLiteral("state"), state }, { QStringLiteral("value"), value } });
    }
    arg.endMap();
    return out;
}
} // namespace

DBusPerformanceBackend::DBusPerformanceBackend(QObject *parent)
    : PerformanceBackend(parent)
    , m_bus(chooseBus())
{
}

void DBusPerformanceBackend::refresh()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetPerformance"));
    const quint64 request = beginRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()
            || !reply.arguments().constFirst().canConvert<QDBusArgument>()) {
            qWarning("ruya-shell: Devices1.System GetPerformance failed: %s", qPrintable(reply.errorMessage()));
            acceptFailure(request);
            return;
        }
        deliver(request, parseMetrics(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}
