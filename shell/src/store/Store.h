#pragma once

#include "StoreBackend.h"

#include <QHash>
#include <QObject>
#include <QQmlEngine>
#include <QSet>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// QML face of org.ruyaos.Store1: the catalogue, the installed apps and the running jobs.
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (ruya-store, T-134) and the
// mock elsewhere, like Audio and Profiles.
//
// App records are plain objects: { id, name, summary, description, developer, source,
// controller, ageRating, permissions, newPermissions, installedSize, icon, tile, hero, installed,
// updateAvailable }. permissions and newPermissions (what the available update adds) are complete
// only after loadApp() of that app has answered.
class Store : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The whole catalogue (search("")), with the installed flags kept current.
    Q_PROPERTY(QVariantList catalogue READ catalogue NOTIFY catalogueChanged)
    // "any" (default) or "gamepad": which apps search() asks the service for (controller "full" or
    // "partial" only). The catalogue stays whole; changing the filter repeats the last search.
    Q_PROPERTY(QString controllerFilter READ controllerFilter WRITE setControllerFilter NOTIFY controllerFilterChanged)
    Q_PROPERTY(QVariantList installed READ installed NOTIFY installedChanged)
    // Result of the last search(); search("") also fills the catalogue.
    Q_PROPERTY(QVariantList results READ results NOTIFY resultsChanged)
    // App id -> { percent, phase } for every job that has reported progress and not finished.
    // When the service loses its bus name (crash, restart) the jobs are dropped and every job it
    // ran or queued ends with jobFinished(id, "failed"); resuming is not attempted. When the
    // service is back, its job table (ListJobs) replaces this map and corrects the apps whose job
    // ended differently than "failed": a job Flatpak completed after all ends with jobFinished(id,
    // "ok"). The same read happens when the shell starts, so a job running then is shown at once.
    Q_PROPERTY(QVariantMap jobs READ jobs NOTIFY jobsChanged)
    // True once the service has answered (always, for the mock).
    Q_PROPERTY(bool available READ isAvailable NOTIFY availableChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Store(std::unique_ptr<StoreBackend> backend, QObject *parent = nullptr);
    ~Store() override;

    static Store *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList catalogue() const { return m_catalogue; }
    QVariantList installed() const { return m_installed; }
    QVariantList results() const { return m_results; }
    QVariantMap jobs() const { return m_jobs; }
    bool isAvailable() const { return m_available; }
    bool isMock() const { return m_backend->isMock(); }
    QString controllerFilter() const { return m_gamepadOnly ? QStringLiteral("gamepad") : QStringLiteral("any"); }
    void setControllerFilter(const QString &filter);

    // Results arrive with searchFinished / results.
    Q_INVOKABLE void search(const QString &query);
    // Results arrive with jobFinished. A refused request (unknown id, busy, ...) finishes with
    // its status and no progress.
    Q_INVOKABLE void install(const QString &appId);
    Q_INVOKABLE void uninstall(const QString &appId, bool deleteData);
    Q_INVOKABLE void update(const QString &appId);
    // Reads one app's permissions (and what its update adds) from the service and merges them into
    // the records held; answers with appLoaded or appLoadFailed. The app page calls it when it opens.
    Q_INVOKABLE void loadApp(const QString &appId);
    // The record of an app from the catalogue, or an empty object.
    Q_INVOKABLE QVariantMap app(const QString &appId) const;

    // Tests only, and only with the mock backend (otherwise false / no-op).
    Q_INVOKABLE bool mockDataDeleted(const QString &appId) const;
    Q_INVOKABLE void mockReset();
    Q_INVOKABLE void mockServiceLost();
    // The service is back: the backend reads the lists and the job table again. finishedApps: apps
    // whose running install or remove Flatpak completed while the service was away.
    Q_INVOKABLE void mockServiceRegained(const QStringList &finishedApps = {});
    // The service ended its running jobs without the shell hearing of it (nothing is emitted).
    Q_INVOKABLE void mockForgetJobs();
    // Running jobs stand still until resumed (no progress, no end).
    Q_INVOKABLE void mockPauseJobs(bool paused);
    // The same, but the shell tracks the jobs (it started them): the job table says how they ended.
    Q_INVOKABLE void mockEndJobsUnheard(const QString &status);
    // The job table has one more finished job of an app, run by another client (after the others).
    Q_INVOKABLE void mockRecordFinishedJob(const QString &appId, const QString &kind, const QString &status);
    // A job-table read whose reply arrives after ms, and how many such replies are still due.
    Q_INVOKABLE void mockListJobsDelayed(int ms);
    Q_INVOKABLE int mockPendingJobLists() const;
    // A job-table read whose call fails.
    Q_INVOKABLE void mockListJobsFailing();
    // A read of the installed list / of the whole catalogue whose reply (a snapshot of now) arrives
    // after ms, and how many such replies are still due.
    Q_INVOKABLE void mockInstalledDelayed(int ms);
    Q_INVOKABLE void mockCatalogueDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;
    Q_INVOKABLE int mockSearchCount() const;
    Q_INVOKABLE void mockCatalogChanged();

signals:
    void catalogueChanged();
    void installedChanged();
    void resultsChanged();
    void jobsChanged();
    void availableChanged();
    void controllerFilterChanged();
    void searchFinished(const QString &query, const QVariantList &apps);
    // status: see api/dbus/org.ruyaos.Store1.xml (JobFinished statuses, plus request statuses).
    void jobFinished(const QString &appId, const QString &status);
    void appLoaded(const QString &appId);
    void appLoadFailed(const QString &appId);
    // The service's job table was applied (after a start or a restart of the service).
    void jobsReconciled();

private:
    QVariantList toList(const QList<AppInfo> &apps) const;
    // Puts the permissions of app into the record of the same id in list; whether it changed.
    bool mergeDetails(QVariantList &list, const AppInfo &app) const;
    // Copies the installed/updateAvailable flags of m_installed into the apps of list.
    bool patchFlags(QVariantList &list) const;

    std::unique_ptr<StoreBackend> m_backend;
    QVariantList m_catalogue;
    QVariantList m_installed;
    QVariantList m_results;
    QVariantMap m_jobs;
    // Apps whose job was given up as failed when the service was lost -> the service's name for
    // that job ("" if unknown). An app leaves it once a later job of it is reported.
    QHash<QString, QString> m_lost;
    QHash<QString, QStringList> m_added; // app id -> what its update adds, from loadApp
    QString m_lastQuery;
    bool m_gamepadOnly = false;
    bool m_available = false;
};
