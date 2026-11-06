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
    const QVariant added = d.value(QStringLiteral("new_permissions"));
    if (added.canConvert<QDBusArgument>())
        a.newPermissions = qdbus_cast<QStringList>(added.value<QDBusArgument>());
    else
        a.newPermissions = added.toStringList();
    a.installedSize = d.value(QStringLiteral("installed_size")).toULongLong();
    a.icon = d.value(QStringLiteral("icon")).toString();
    a.tile = d.value(QStringLiteral("tile")).toString();
    a.hero = d.value(QStringLiteral("hero")).toString();
    a.installed = d.value(QStringLiteral("installed")).toBool();
    a.updateAvailable = d.value(QStringLiteral("update_available")).toBool();
    return a;
}

StoreJob toJob(const QVariantMap &d)
{
    StoreJob j;
    j.id = d.value(QStringLiteral("id")).toString();
    j.appId = d.value(QStringLiteral("app")).toString();
    j.kind = d.value(QStringLiteral("kind")).toString();
    j.state = d.value(QStringLiteral("state")).toString();
    j.status = d.value(QStringLiteral("status")).toString();
    j.reason = d.value(QStringLiteral("reason")).toString();
    j.percent = d.value(QStringLiteral("percent")).toUInt();
    j.phase = d.value(QStringLiteral("phase")).toString();
    return j;
}

// aa{sv}
QList<StoreJob> parseJobs(const QDBusArgument &arg)
{
    QList<StoreJob> out;
    arg.beginArray();
    while (!arg.atEnd())
        out.append(toJob(parseDict(arg)));
    arg.endArray();
    return out;
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
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForOwnerChange, this)
{
    // An old owner that goes away, or is replaced directly by a new one, took its jobs with it.
    connect(&m_watcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &oldOwner, const QString &) {
        if (oldOwner.isEmpty())
            return;
        emit serviceLost(jobBook().lose()); // running and queued jobs the client knows
    });
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] {
        refresh();
        search(QString(), false, 0);
        listJobs(); // what became of the jobs the old owner took with it
    });
    m_bus.connect(Service, Path, Interface, QStringLiteral("InstalledChanged"), this, SIGNAL(installedChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("CatalogChanged"), this, SIGNAL(catalogChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("JobProgress"), this,
                  SLOT(onJobProgress(QString, uint, QString)));
    m_bus.connect(Service, Path, Interface, QStringLiteral("JobFinished"), this, SLOT(onJobFinished(QString, QString)));
}

void DBusStoreBackend::refresh()
{
    // InstalledChanged can arrive before the reply of the call that caused it, and the service
    // answers concurrently, so two replies can arrive out of order: the newest one wins.
    const quint64 request = beginInstalledRequest();
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListInstalled"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Store1 ListInstalled failed: %s", qPrintable(reply.errorMessage()));
            acceptInstalled(request); // a failure is an outcome too: an older reply after it is stale
            return;
        }
        deliverInstalled(request, parseApps(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}

void DBusStoreBackend::listJobs()
{
    const quint64 request = jobBook().listSent();
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListJobs"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Store1 ListJobs failed: %s", qPrintable(reply.errorMessage()));
            jobBook().listFailed(request);
            return;
        }
        jobBook().listAnswered(request, parseJobs(reply.arguments().constFirst().value<QDBusArgument>()));
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
    const quint64 request = beginSearchRequest(query, gamepadOnly);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, query, gamepadOnly, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Store1 Search failed: %s", qPrintable(reply.errorMessage()));
            acceptSearch(query, gamepadOnly, request); // a failure is an outcome too
            return;
        }
        deliverSearch(query, gamepadOnly, request, parseApps(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}

void DBusStoreBackend::getApp(const QString &id)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetApp"));
    msg << id;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        // (status s, app a{sv})
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().size() < 2
            || reply.arguments().at(0).toString() != QLatin1String("ok")) {
            qWarning("ruya-shell: Store1 GetApp %s failed: %s", qPrintable(id), qPrintable(reply.errorMessage()));
            emit appLoadFailed(id);
            return;
        }
        emit appLoaded(toApp(parseDict(reply.arguments().at(1).value<QDBusArgument>())));
    });
}

void DBusStoreBackend::startJob(const QString &method, const QString &id, const QVariantList &args)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg.setArguments(args);
    jobBook().callSent(); // signals of the job it names may arrive before its reply (JobBook.h)
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, method, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString, QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Store1 %s %s failed: %s", qPrintable(method), qPrintable(id),
                     qPrintable(reply.error().message()));
            jobBook().callEnded();
            emit jobFinished(id, QStringLiteral("failed"));
            return;
        }
        const QString status = reply.argumentAt<0>();
        const QString job = reply.argumentAt<1>();
        if (status == QLatin1String("ok") && !job.isEmpty()) {
            jobBook().callAnswered(job, id); // progress and the result arrive as signals
        } else {
            jobBook().callEnded();
            emit jobFinished(id, status);
        }
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
    jobBook().onProgress(job, percent, phase);
}

void DBusStoreBackend::onJobFinished(const QString &job, const QString &status)
{
    jobBook().onFinished(job, status);
}
