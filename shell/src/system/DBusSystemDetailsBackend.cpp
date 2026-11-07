#include "DBusSystemDetailsBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Devices1");
const QString Path = QStringLiteral("/org/ruyaos/Devices1");
const QString Interface = QStringLiteral("org.ruyaos.Devices1.System");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}

QVariantMap parseDict(const QDBusArgument &arg);

// A value of the dictionary: a plain value, or a table (aa{sv}) as a list of dictionaries.
QVariant plain(const QVariant &value)
{
    if (!value.canConvert<QDBusArgument>())
        return value;
    const QDBusArgument arg = value.value<QDBusArgument>();
    if (arg.currentType() == QDBusArgument::ArrayType) {
        QVariantList rows;
        arg.beginArray();
        while (!arg.atEnd())
            rows.append(parseDict(arg));
        arg.endArray();
        return rows;
    }
    if (arg.currentType() == QDBusArgument::MapType)
        return parseDict(arg);
    return {};
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
        const QVariant v = plain(value.variant());
        if (v.isValid())
            out.insert(key, v);
    }
    arg.endMap();
    return out;
}
} // namespace

DBusSystemDetailsBackend::DBusSystemDetailsBackend(QObject *parent)
    : SystemDetailsBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("SystemInfoChanged"), this, SLOT(onChanged()));
}

void DBusSystemDetailsBackend::refresh()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetInfo"));
    const quint64 request = beginRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.System GetInfo failed: %s", qPrintable(reply.errorMessage()));
            acceptFailure(request);
            return;
        }
        deliver(request, parseDict(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}
