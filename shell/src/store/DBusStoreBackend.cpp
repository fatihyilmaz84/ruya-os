#include "DBusStoreBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Store1");
const QString Path = QStringLiteral("/org/ruyaos/Store1");
const QString Interface = QStringLiteral("org.ruyaos.Store1");

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

AppInfo toApp(const QVariantMap &d)
{
    AppInfo a;
    a.id = d.value(QStringLiteral("id")).toString();
    a.name = d.value(QStringLiteral("name")).toString();
    a.summary = d.value(QStringLiteral("summary")).toString();
    a.description = d.value(QStringLiteral("description")).toString();
    a.developer = d.value(QStringLiteral("developer")).toString();
    a.source = d.value(QStringLiteral("source"), a.source).toString();
    a.controller = d.value(QStringLiteral("controller"), a.controller).toString();
    a.ageRating = d.value(QStringLiteral("age_rating"), a.ageRating).toString();
    const QVariant perms = d.value(QStringLiteral("permissions"));
    if (perms.canConvert<QDBusArgument>())
        a.permissions = qdbus_cast<QStringList>(perms.value<QDBusArgument>());
    else
        a.permissions = perms.toStringList();
    a.installedSize = d.value(QStringLiteral("installed_size")).toULongLong();
    a.icon = d.value(QStringLiteral("icon")).toString();
    a.tile = d.value(QStringLiteral("tile")).toString();
    a.hero = d.value(QStringLiteral("hero")).toString();
    a.installed = d.value(QStringLiteral("installed")).toBool();
    a.updateAvailable = d.value(QStringLiteral("update_available")).toBool();
    return a;
}

// aa{sv}
QList<AppInfo> parseApps(const QDBusArgument &arg)
{
    QList<AppInfo> out;
    arg.beginArray();
    while (!arg.atEnd())
        out.append(toApp(parseDict(arg)));
    arg.endArray();
    return out;
}
} // namespace

DBusStoreBackend::DBusStoreBackend(QObject *parent)
    : StoreBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] {
        refresh();
        search(QString(), false, 0);
    });
    m_bus.connect(Service, Path, Interface, QStringLiteral("InstalledChanged"), this, SIGNAL(installedChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("CatalogChanged"), this, SIGNAL(catalogChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("JobProgress"), this,
                  SLOT(onJobProgress(QString, uint, QString)));
    m_bus.connect(Service, Path, Interface, QStringLiteral("JobFinished"), this, SLOT(onJobFinished(QString, QString)));
}

void DBusStoreBackend::refresh()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListInstalled"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Store1 ListInstalled failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        emit installedListed(parseApps(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}

void DBusStoreBackend::search(const QString &query, bool gamepadOnly, uint limit)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Search"));
    QVariantMap options; // a{sv}
    if (gamepadOnly)
        options.insert(QStringLiteral("controller"), QStringLiteral("gamepad"));
    if (limit != 0)
        options.insert(QStringLiteral("limit"), limit);
    msg << query << options;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, query, gamepadOnly](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Store1 Search failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        emit searchFinished(query, gamepadOnly, parseApps(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}

void DBusStoreBackend::startJob(const QString &method, const QString &id, const QVariantList &args)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg.setArguments(args);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, method, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString, QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Store1 %s %s failed: %s", qPrintable(method), qPrintable(id),
                     qPrintable(reply.error().message()));
            emit jobFinished(id, QStringLiteral("failed"));
            return;
        }
        const QString status = reply.argumentAt<0>();
        const QString job = reply.argumentAt<1>();
        if (status == QLatin1String("ok") && !job.isEmpty())
            m_jobApps.insert(job, id); // progress and the result arrive as signals
        else
            emit jobFinished(id, status);
    });
}

void DBusStoreBackend::install(const QString &id)
{
    startJob(QStringLiteral("Install"), id, {id});
}

void DBusStoreBackend::uninstall(const QString &id, bool deleteData)
{
    startJob(QStringLiteral("Uninstall"), id, {id, deleteData});
}

void DBusStoreBackend::update(const QString &id)
{
    startJob(QStringLiteral("Update"), id, {id});
}

void DBusStoreBackend::onJobProgress(const QString &job, uint percent, const QString &phase)
{
    const auto it = m_jobApps.constFind(job);
    if (it != m_jobApps.cend())
        emit jobProgress(it.value(), int(percent), phase);
}

void DBusStoreBackend::onJobFinished(const QString &job, const QString &status)
{
    const QString id = m_jobApps.take(job);
    if (!id.isEmpty())
        emit jobFinished(id, status);
}
