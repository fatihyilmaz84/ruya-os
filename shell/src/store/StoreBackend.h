#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
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
    QString ageRating = QStringLiteral("all");
    QStringList permissions;
    QStringList newPermissions; // what the available update adds; only getApp fills it
    qulonglong installedSize = 0;
    QString icon;
    QString tile;
    QString hero;
    bool installed = false;
    bool updateAvailable = false;

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
            {QStringLiteral("icon"), icon},
            {QStringLiteral("tile"), tile},
            {QStringLiteral("hero"), hero},
            {QStringLiteral("installed"), installed},
            {QStringLiteral("updateAvailable"), updateAvailable},
        };
    }
};

// One record of ListJobs (api/dbus/org.ruyaos.Store1.xml, "ListJobs").
struct StoreJob
{
    QString id;     // the service's name for the job
    QString appId;
    QString kind;   // "install" | "remove" | "update" | "rollback"
    QString state;  // "queued" | "running" | "finished"
    QString status; // "" unless finished: "ok", "failed", ...
    QString reason; // "" or "interrupted" (the service died while it ran)
    uint percent = 0;
    QString phase;
};

// Transport behind the Store QML singleton: org.ruyaos.Store1 over D-Bus, or an in-memory mock.
// Results arrive asynchronously through signals. The backend, not the facade, maps the service's
// job ids to app ids.
class StoreBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

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
    // and will never report again. appIds: every app the backend had a job for, running or queued.
    void serviceLost(const QStringList &appIds);
    // The service's job table. The facade shows its running jobs and nothing else, and corrects
    // the apps whose jobs it had given up on when the service was lost.
    void jobsListed(const QList<StoreJob> &jobs);

protected:
    // Replies can arrive out of order: number each ListJobs request when it is sent and report a
    // reply only if no newer one has been reported already (RequestSequence.h, T-181).
    quint64 beginJobsRequest() { return m_jobsSeq.begin(); }
    // True when this reply is the newest so far (and is reported by deliverJobs).
    bool acceptJobs(quint64 request) { return m_jobsSeq.accept(request); }
    void deliverJobs(quint64 request, const QList<StoreJob> &jobs)
    {
        if (acceptJobs(request))
            emit jobsListed(jobs);
    }

private:
    RequestSequence m_jobsSeq;
};
