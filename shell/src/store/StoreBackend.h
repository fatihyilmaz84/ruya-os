#pragma once

#include "JobBook.h"
#include "RequestSequence.h"

#include <QHash>
#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

// One app record of org.ruyaos.Store1 (api/dbus/org.ruyaos.Store1.xml, "App record").
struct AppInfo
{
    QString id;
    QString name;
    QString summary;
    QString description;
    QString developer;
    QString source = QStringLiteral("community"); // "official" | "community" | "developer"
    QString controller = QStringLiteral("none");  // "full" | "partial" | "none"
    QString ageRating;   // "all" | "7+" | ... ; empty = not rated
    QStringList permissions;
    QStringList newPermissions; // what the available update adds; only getApp fills it
    qulonglong installedSize = 0;
    qulonglong downloadSize = 0; // bytes an install downloads; 0 = unknown
    QString version;          // newest release in the remote; empty = unknown
    qint64 releaseDate = 0;   // unix seconds of that release; 0 = unknown
    QString releaseNotes;     // plain text; only getApp fills it
    QString installedVersion; // installed apps; empty = unknown
    QString license;          // SPDX expression; empty = none
    QStringList categories;   // raw AppStream names
    QVariantList screenshots; // [{image, thumb, caption}]; only getApp fills it
    QString icon;
    QString tile;
    QString hero;
    bool installed = false;
    bool updateAvailable = false;
    bool compatible = true; // false: needs a newer API level than this console has (hidden from lists)
    int minApiLevel = 0; // the level the app asks for, 0 = none (the mock computes compatible from it)

    // The record as QML sees it (camelCase keys).
    QVariantMap toVariant() const
    {
        return {
            {QStringLiteral("id"), id},
            {QStringLiteral("name"), name},
            {QStringLiteral("summary"), summary},
            {QStringLiteral("description"), description},
            {QStringLiteral("developer"), developer},
            {QStringLiteral("source"), source},
            {QStringLiteral("controller"), controller},
            {QStringLiteral("ageRating"), ageRating},
            {QStringLiteral("permissions"), permissions},
            {QStringLiteral("newPermissions"), newPermissions},
            {QStringLiteral("installedSize"), installedSize},
            {QStringLiteral("downloadSize"), downloadSize},
            {QStringLiteral("version"), version},
            {QStringLiteral("releaseDate"), releaseDate},
            {QStringLiteral("releaseNotes"), releaseNotes},
            {QStringLiteral("installedVersion"), installedVersion},
            {QStringLiteral("license"), license},
            {QStringLiteral("categories"), categories},
            {QStringLiteral("screenshots"), screenshots},
            {QStringLiteral("icon"), icon},
            {QStringLiteral("tile"), tile},
            {QStringLiteral("hero"), hero},
            {QStringLiteral("installed"), installed},
            {QStringLiteral("updateAvailable"), updateAvailable},
            {QStringLiteral("compatible"), compatible},
            {QStringLiteral("minApiLevel"), minApiLevel},
        };
    }
};

// Transport behind the Store QML singleton: org.ruyaos.Store1 over D-Bus, or an in-memory mock.
// Results arrive asynchronously through signals. The backend, not the facade, maps the service's
// job ids to app ids.
class StoreBackend : public QObject
{
    Q_OBJECT

public:
    explicit StoreBackend(QObject *parent = nullptr)
        : QObject(parent)
        , m_jobs(this)
    {
        // The job book maps the service's job ids to app ids (and keeps the races of the job table
        // apart, JobBook.h); what it reports is what the backend reports.
        connect(&m_jobs, &JobBook::jobProgress, this, &StoreBackend::jobProgress);
        connect(&m_jobs, &JobBook::jobFinished, this, &StoreBackend::jobFinished);
        connect(&m_jobs, &JobBook::jobsListed, this, &StoreBackend::jobsListed);
    }

    virtual bool isMock() const = 0;
    virtual void refresh() = 0;                           // reports the installed list
    // "" = the whole catalogue. gamepadOnly: only apps with controller "full" or "partial";
    // limit 0 = no limit.
    virtual void search(const QString &query, bool gamepadOnly, uint limit) = 0;
    virtual void install(const QString &id) = 0;
    virtual void uninstall(const QString &id, bool deleteData) = 0;
    virtual void update(const QString &id) = 0;
    // One app with its permissions and, for an installed app with an update, what the update adds.
    // Answers with appLoaded or appLoadFailed.
    virtual void getApp(const QString &id) = 0;
    // Asks the service for its job table (jobs queued or running and the last finished ones, oldest
    // first). Called at start and whenever the service's name has a new owner; answers with
    // jobsListed. A reply older than one already reported is dropped.
    virtual void listJobs() = 0;
    // The permissions of an installed app (GetPermissions, RUY-744). Answers with permissionsLoaded; a
    // reply older than one already reported for the same app is dropped.
    virtual void getPermissions(const QString &id) = 0;
    // How many permissions the console withdraws, for every installed app at once (GetWithdrawnCounts,
    // RUY-1190). Answers with withdrawnCountsLoaded; a reply older than one already reported is dropped.
    virtual void getWithdrawnCounts() = 0;
    // Admin only (the service checks the caller). Each answers with permissionChanged(id, key, status);
    // resetPermissions with key "".
    virtual void withdrawPermission(const QString &id, const QString &key) = 0;
    virtual void restorePermission(const QString &id, const QString &key) = 0;
    virtual void resetPermissions(const QString &id) = 0;

signals:
    void appLoaded(const AppInfo &app);
    void appLoadFailed(const QString &id);
    void searchFinished(const QString &query, bool gamepadOnly, const QList<AppInfo> &apps);
    void installedListed(const QList<AppInfo> &apps);
    // The set of installed apps or an update flag changed: the facade reads the installed list
    // again and patches the flags of the apps it holds.
    void installedChanged();
    // The catalogue was (re)read by the service: the facade searches again.
    void catalogChanged();
    void jobProgress(const QString &appId, int percent, const QString &phase);
    // status: see the XML ("ok", "failed", "network", ...). A request the service refused
    // ("unknown-app", "busy", ...) is reported the same way, without any progress before it.
    void jobFinished(const QString &appId, const QString &status);
    // The service's bus name lost its owner (it crashed or restarted): every job it ran is gone
    // and will never report again. jobApps: every job the backend had (job id -> app id), running
    // or queued.
    void serviceLost(const QHash<QString, QString> &jobApps);
    // The service's job table, brought up to date with the signals that arrived after it was asked
    // for (JobBook.h). The facade shows its running jobs and nothing else, and corrects the apps
    // whose jobs it had given up on when the service was lost.
    void jobsListed(const QList<StoreJob> &jobs);
    // status: see the XML ("ok", "unknown-app", "failed", ...; a failed call is "failed"). effective: what
    // the app gets now; withdrawn: what the console's override takes away; withdrawable: what an admin can
    // withdraw on this console. The lists are empty unless status is "ok".
    void permissionsLoaded(const QString &id, const QString &status, const QStringList &effective,
                           const QStringList &withdrawn, const QStringList &withdrawable);
    void permissionChanged(const QString &id, const QString &key, const QString &status);
    // app id -> how many of its permissions are withdrawn (an int), only the apps that have any. Empty when the
    // call failed: nothing is known to be withdrawn, and an older answer is not shown in its place.
    void withdrawnCountsLoaded(const QVariantMap &counts);

protected:
    // Replies can arrive out of order: number each request when it is sent and report a reply only
    // if no newer one has been reported already; a failed request counts as reported (a failure is
    // an outcome too) (RequestSequence.h, T-181, T-191). The installed list is one sequence, the
    // job table is kept by the JobBook, and each search (query, filter) has its own.
    quint64 beginInstalledRequest() { return m_installedSeq.begin(); }
    bool acceptInstalled(quint64 request) { return m_installedSeq.accept(request); }
    void deliverInstalled(quint64 request, const QList<AppInfo> &apps)
    {
        if (acceptInstalled(request))
            emit installedListed(apps);
    }
    quint64 beginSearchRequest(const QString &query, bool gamepadOnly)
    {
        return m_searchSeq[searchKey(query, gamepadOnly)].begin();
    }
    bool acceptSearch(const QString &query, bool gamepadOnly, quint64 request)
    {
        return m_searchSeq[searchKey(query, gamepadOnly)].accept(request);
    }
    void deliverSearch(const QString &query, bool gamepadOnly, quint64 request, const QList<AppInfo> &apps)
    {
        if (acceptSearch(query, gamepadOnly, request))
            emit searchFinished(query, gamepadOnly, apps);
    }
    JobBook &jobBook() { return m_jobs; }
    // One sequence per app: a slow answer about one app never drops a newer one about another.
    quint64 beginPermissionsRequest(const QString &id) { return m_permissionsSeq[id].begin(); }
    void deliverPermissions(const QString &id, quint64 request, const QString &status, const QStringList &effective,
                            const QStringList &withdrawn, const QStringList &withdrawable)
    {
        if (m_permissionsSeq[id].accept(request))
            emit permissionsLoaded(id, status, effective, withdrawn, withdrawable);
    }
    // The batch is one sequence: any newer reply, a failure included, makes an older one stale.
    quint64 beginWithdrawnCountsRequest() { return m_withdrawnCountsSeq.begin(); }
    void deliverWithdrawnCounts(quint64 request, const QVariantMap &counts)
    {
        if (m_withdrawnCountsSeq.accept(request))
            emit withdrawnCountsLoaded(counts);
    }

private:
    static QString searchKey(const QString &query, bool gamepadOnly)
    {
        return (gamepadOnly ? QStringLiteral("g:") : QStringLiteral("a:")) + query;
    }

    RequestSequence m_installedSeq;
    QHash<QString, RequestSequence> m_searchSeq;
    QHash<QString, RequestSequence> m_permissionsSeq;
    RequestSequence m_withdrawnCountsSeq;
    JobBook m_jobs;
};
