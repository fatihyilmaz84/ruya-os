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
// it reads the lists and the job table again. Its job signals go through the same JobBook as the
// D-Bus client's (T-191), under job names of its own, so the races of the job table can be tested.
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
    // signal) and does not track them (it never knew them): they are in the job table as failed,
    // with no JobFinished.
    void forgetJobs();
    // Tests only: running jobs stand still (no progress, no end) until resumed.
    void pauseJobs(bool paused);
    // Tests only: the same, but the shell tracks the jobs (it started them) and the job table says
    // how they ended: status. The app records stay as they are.
    void endJobsUnheard(const QString &status);
    // Tests only: the job table has one more finished job (another client ran it), after the others.
    void recordFinishedJob(const QString &appId, const QString &kind, const QString &status);
    // Tests only: ask for the job table, but deliver the reply after ms (a slow service).
    void listJobsDelayed(int ms);
    // Tests only: ask for the job table, and the call fails.
    void listJobsFailing();
    // Tests only: ask for the installed list / the whole catalogue, but deliver the reply (a
    // snapshot of now) after ms.
    void refreshDelayed(int ms);
    void searchDelayed(int ms);
    // Tests only: every later search() answers after ms (0, the default: on the next turn of the
    // event loop) until reset() (T-377).
    void setSearchReplyMs(int ms) { m_searchReplyMs = ms; }
    int pendingJobLists() const { return m_pendingJobLists; }
    int pendingReplies() const { return m_pendingReplies; }
    int searchCount() const { return m_searchCount; }
    void announceCatalogChanged() { emit catalogChanged(); }
    // Tests only: an app's text as AppStream could carry it (any text), and, when given, its permission ids
    // (also the ones an update adds); then CatalogChanged.
    void setAppText(const QString &id, const QString &name, const QString &summary, const QString &developer,
                    const QStringList &permissions = {});
    // Tests only: a tile picture for every app (see mockArtPath), then CatalogChanged.
    void setArtDir(const QString &dir);
    // Tests only: `count` more community apps (org.example.Many0...), one in five with full controller
    // support and one in five partial, the size of a real remote's catalogue; then CatalogChanged (T-377).
    void addApps(int count);

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
    void refreshAfter(int ms);
    void searchAfter(const QString &query, bool gamepadOnly, uint limit, int ms);
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
    int m_pendingReplies = 0; // installed list and search replies not delivered yet
    QSet<QString> m_dataDeleted;
    QTimer m_timer;
    int m_stepMs = 100;
    int m_searchCount = 0;
    int m_searchReplyMs = 0;
    bool m_paused = false;
};
