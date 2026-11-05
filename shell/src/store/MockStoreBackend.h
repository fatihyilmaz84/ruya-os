#pragma once

#include "StoreBackend.h"

#include <QHash>
#include <QSet>
#include <QTimer>

// In-memory store: a catalogue of 12 apps (all sources and controller levels), three installed
// from the start, two of them with an update: Open Chess adds "all-devices" (reported by getApp
// only, as the service does), Text Editor adds nothing. An install runs download (0-49) then install
// (50-100) in 20 steps of about 100 ms (10 ms with RUYA_MOCK_FAST=1), then reports
// InstalledChanged and ok. "org.example.Broken" always fails part-way. Like the service it keeps a
// job table (listJobs): the jobs queued or running and a record of each finished one. Losing the
// service ends its jobs as "failed, interrupted"; regainService() plays the new service owner:
// it reads the lists and the job table again.
class MockStoreBackend final : public StoreBackend
{
    Q_OBJECT

public:
    explicit MockStoreBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void search(const QString &query, bool gamepadOnly, uint limit) override;
    void install(const QString &id) override;
    void uninstall(const QString &id, bool deleteData) override;
    void update(const QString &id) override;
    void getApp(const QString &id) override;
    void listJobs() override;

    // Tests only: whether an uninstall of this app asked for its data to be deleted.
    bool dataDeleted(const QString &id) const { return m_dataDeleted.contains(id); }
    void reset();
    // Tests only: the service went away mid-job; running jobs vanish without a JobFinished.
    void loseService();
    // Tests only: the service is back (a restart). finishedApps: apps whose running install or
    // remove Flatpak completed while the service was away; the new service finds them done. Then
    // the shell's side of a new owner: read the installed list, the catalogue and the job table.
    void regainService(const QStringList &finishedApps);
    // Tests only: the service ended its running jobs and the shell heard nothing of it (a lost
    // signal): they are in the job table as failed, with no JobFinished.
    void forgetJobs();
    // Tests only: ask for the job table, but deliver the reply after ms (a slow service).
    void listJobsDelayed(int ms);
    int pendingJobLists() const { return m_pendingJobLists; }
    int searchCount() const { return m_searchCount; }
    void announceCatalogChanged() { emit catalogChanged(); }

private:
    struct Job
    {
        QString id; // the app; the mock's job names are in jobId
        enum Kind { Install, Update, Uninstall } kind = Install;
        int percent = 0;
        QString jobId;
    };

    void initState();
    int indexOf(const QString &id) const;
    void startJob(const QString &id, Job::Kind kind);
    void step();
    void finish(const Job &job, const QString &status);
    void reject(const QString &id, const QString &status);
    QList<AppInfo> installedApps() const;
    QList<StoreJob> jobTable() const;
    static QString kindName(Job::Kind kind);
    static AppInfo listed(AppInfo a);

    QList<AppInfo> m_apps;
    QList<Job> m_jobs; // one transaction queue: only the first runs
    QList<StoreJob> m_finishedJobs; // the service's record of jobs that ended
    int m_jobCounter = 0;
    int m_pendingJobLists = 0;
    QSet<QString> m_dataDeleted;
    QTimer m_timer;
    int m_stepMs = 100;
    int m_searchCount = 0;
};
