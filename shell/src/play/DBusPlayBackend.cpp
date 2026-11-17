#include "DBusPlayBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Play1");
const QString Path = QStringLiteral("/org/ruyaos/Play1");
const QString Interface = QStringLiteral("org.ruyaos.Play1");

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

// a{ss}
QVariantMap parseStringMap(const QDBusArgument &arg)
{
    QVariantMap out;
    arg.beginMap();
    while (!arg.atEnd()) {
        QString key;
        QString value;
        arg.beginMapEntry();
        arg >> key >> value;
        arg.endMapEntry();
        out.insert(key, value);
    }
    arg.endMap();
    return out;
}

// a(sss): three strings per structure
QList<QStringList> parseTriples(const QDBusArgument &arg)
{
    QList<QStringList> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        QString a;
        QString b;
        QString c;
        arg.beginStructure();
        arg >> a >> b >> c;
        arg.endStructure();
        out.append({a, b, c});
    }
    arg.endArray();
    return out;
}

QStringList stringList(const QVariant &v)
{
    return v.canConvert<QDBusArgument>() ? qdbus_cast<QStringList>(v.value<QDBusArgument>()) : v.toStringList();
}

PlayInfo toInfo(const QString &path, const QVariantMap &d)
{
    PlayInfo i;
    i.path = path;
    i.id = d.value(QStringLiteral("id")).toString();
    i.name = d.value(QStringLiteral("name")).toString();
    i.summary = d.value(QStringLiteral("summary")).toString();
    i.version = d.value(QStringLiteral("version")).toString();
    i.build = d.value(QStringLiteral("build")).toUInt();
    i.developer = d.value(QStringLiteral("developer")).toString();
    i.genres = stringList(d.value(QStringLiteral("genres")));
    i.players = d.value(QStringLiteral("players")).toString();
    i.controller = d.value(QStringLiteral("controller"), i.controller).toString();
    i.ageLabel = d.value(QStringLiteral("age_label")).toString();
    i.size = d.value(QStringLiteral("size")).toULongLong();
    i.requirement = d.value(QStringLiteral("requirement"), i.requirement).toString();
    i.verdict = d.value(QStringLiteral("verdict"), i.verdict).toString();
    i.tier = d.value(QStringLiteral("tier"), i.tier).toString();
    i.signerKeyId = d.value(QStringLiteral("signer_key_id")).toString();
    i.signerName = d.value(QStringLiteral("signer_name")).toString();
    i.keyState = d.value(QStringLiteral("key_state")).toString();
    const QVariant perms = d.value(QStringLiteral("permissions"));
    if (perms.canConvert<QDBusArgument>()) {
        for (const QStringList &t : parseTriples(perms.value<QDBusArgument>()))
            i.permissions.append({t.at(0), t.at(1), t.at(2)});
    }
    const QVariant art = d.value(QStringLiteral("art"));
    if (art.canConvert<QDBusArgument>())
        i.art = parseStringMap(art.value<QDBusArgument>());
    i.screenshots = stringList(d.value(QStringLiteral("screenshots")));
    i.revoked = d.value(QStringLiteral("revoked")).toBool();
    i.installedBuild = d.value(QStringLiteral("installed_build")).toUInt();
    const QVariant probs = d.value(QStringLiteral("problems"));
    if (probs.canConvert<QDBusArgument>()) {
        for (const QStringList &t : parseTriples(probs.value<QDBusArgument>()))
            i.problems.append({t.at(0), t.at(1), t.at(2)});
    }
    return i;
}

PlaySource toSource(const QVariantMap &d)
{
    PlaySource s;
    s.drive = d.value(QStringLiteral("drive")).toString();
    s.driveLabel = d.value(QStringLiteral("drive_label")).toString();
    s.path = d.value(QStringLiteral("path")).toString();
    s.name = d.value(QStringLiteral("name")).toString();
    s.kind = d.value(QStringLiteral("kind")).toString();
    s.size = d.value(QStringLiteral("size")).toULongLong();
    return s;
}

// The job record: the facade's key is the package path of an install and the app id of a verify.
StoreJob toJob(const QVariantMap &d)
{
    StoreJob j;
    j.id = d.value(QStringLiteral("id")).toString();
    j.kind = d.value(QStringLiteral("kind")).toString();
    j.appId = j.kind == QLatin1String("install") ? d.value(QStringLiteral("path")).toString()
                                                  : d.value(QStringLiteral("app")).toString();
    j.state = d.value(QStringLiteral("state")).toString();
    j.status = d.value(QStringLiteral("status")).toString();
    j.reason = d.value(QStringLiteral("reason")).toString();
    j.percent = d.value(QStringLiteral("percent")).toUInt();
    j.phase = d.value(QStringLiteral("phase")).toString();
    return j;
}

// aa{sv}
template<typename T, typename F>
QList<T> parseRecords(const QDBusArgument &arg, F convert)
{
    QList<T> out;
    arg.beginArray();
    while (!arg.atEnd())
        out.append(convert(parseDict(arg)));
    arg.endArray();
    return out;
}
} // namespace

DBusPlayBackend::DBusPlayBackend(QObject *parent)
    : PlayBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForOwnerChange, this)
{
    // An old owner that goes away, or is replaced directly by a new one, took its jobs with it.
    connect(&m_watcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &oldOwner, const QString &) {
        if (oldOwner.isEmpty())
            return;
        emit serviceLost(jobBook().lose());
    });
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] {
        listSources();
        listJobs(); // what became of the jobs the old owner took with it
    });
    m_bus.connect(Service, Path, Interface, QStringLiteral("SourcesChanged"), this, SIGNAL(sourcesChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("JobProgress"), this,
                  SLOT(onJobProgress(QString, uint, QString)));
    m_bus.connect(Service, Path, Interface, QStringLiteral("JobFinished"), this, SLOT(onJobFinished(QString, QString)));
}

void DBusPlayBackend::listSources()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListSources"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Play1 ListSources failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        emit sourcesListed(parseRecords<PlaySource>(reply.arguments().constFirst().value<QDBusArgument>(), toSource));
    });
}

void DBusPlayBackend::inspect(const QString &path)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Inspect"));
    msg << path;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, path](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        // (status s, info a{sv})
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().size() < 2) {
            qWarning("ruya-shell: Play1 Inspect %s failed: %s", qPrintable(path), qPrintable(reply.errorMessage()));
            emit answered(QStringLiteral("inspect"), path, QStringLiteral("failed"));
            return;
        }
        const QString status = reply.arguments().at(0).toString();
        emit answered(QStringLiteral("inspect"), path, status);
        if (status == QLatin1String("ok"))
            emit inspected(path, toInfo(path, parseDict(reply.arguments().at(1).value<QDBusArgument>())));
    });
}

void DBusPlayBackend::startJob(const QString &op, const QString &method, const QString &key, const QVariantList &args)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg.setArguments(args);
    jobBook().callSent(); // signals of the job it names may arrive before its reply (JobBook.h)
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, op, method, key](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString, QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Play1 %s %s failed: %s", qPrintable(method), qPrintable(key),
                     qPrintable(reply.error().message()));
            jobBook().callEnded();
            emit answered(op, key, QStringLiteral("failed"));
            return;
        }
        const QString status = reply.argumentAt<0>();
        const QString job = reply.argumentAt<1>();
        if (status == QLatin1String("ok") && !job.isEmpty()) {
            emit answered(op, key, status); // before the signals that overtook this reply are replayed
            jobBook().callAnswered(job, key); // progress and the result arrive as signals
        } else {
            jobBook().callEnded();
            emit answered(op, key, status == QLatin1String("ok") ? QStringLiteral("failed") : status);
        }
    });
}

void DBusPlayBackend::install(const QString &path, bool adminApproved)
{
    const QVariantMap options{{QStringLiteral("admin_approved"), adminApproved}}; // a{sv}
    startJob(QStringLiteral("install"), QStringLiteral("Install"), path, {path, options});
}

void DBusPlayBackend::verify(const QString &appId)
{
    startJob(QStringLiteral("verify"), QStringLiteral("Verify"), appId, {appId});
}

void DBusPlayBackend::cancel(const QString &key)
{
    const QString job = jobBook().jobFor(key);
    if (job.isEmpty()) { // the shell knows no such job (it finished, or was never accepted)
        emit answered(QStringLiteral("cancel"), key, QStringLiteral("unknown-job"));
        return;
    }
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Cancel"));
    msg << job;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, key](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Play1 Cancel %s failed: %s", qPrintable(key), qPrintable(reply.error().message()));
            emit answered(QStringLiteral("cancel"), key, QStringLiteral("failed"));
            return;
        }
        emit answered(QStringLiteral("cancel"), key, reply.argumentAt<0>());
    });
}

void DBusPlayBackend::listJobs()
{
    const quint64 request = jobBook().listSent();
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListJobs"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Play1 ListJobs failed: %s", qPrintable(reply.errorMessage()));
            jobBook().listFailed(request);
            return;
        }
        jobBook().listAnswered(request, parseRecords<StoreJob>(reply.arguments().constFirst().value<QDBusArgument>(), toJob));
    });
}

void DBusPlayBackend::onJobProgress(const QString &job, uint percent, const QString &phase)
{
    jobBook().onProgress(job, percent, phase);
}

void DBusPlayBackend::onJobFinished(const QString &job, const QString &status)
{
    jobBook().onFinished(job, status);
}
