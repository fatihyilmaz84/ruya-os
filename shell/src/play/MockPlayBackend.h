#pragma once

#include "PlayBackend.h"

#include <QSet>
#include <QTimer>

// In-memory ruya-play (the service is RUY-100, not built yet): follows api/dbus/org.ruyaos.Play1.xml,
// method statuses and job statuses included. One drive ("vol-stick", "STICK") with 13 packages, each
// a fixture for one outcome:
//   starhopper    a Wine game with a full permission set, developer tier, key new      -> ok
//   pixelforest   a native game, official tier, key same, build 3 (build 2 installed) -> ok
//   homebrew      unverified                      -> needs-developer-mode (ok with developer mode on)
//   oldbad        developer tier, on the block list                                    -> revoked
//   broken        hash mismatch and a missing file (05 §4.5)                           -> invalid-package
//   rawaccess     high-risk permissions (all devices, devel)                           -> ok
//   rawofficial   the same requests, official tier: gate admin-pin                           -> ok
//   rawunverified unverified with a high-risk request: no gate, ceiling.refused           -> invalid-package
//   impostor      the id is installed under another key                                -> different-developer
//   tampered      changed after it was signed                                          -> bad-signature
//   future        format.too_new                                                       -> unsupported
//   hugegame      bigger than the free space                                           -> disk-full
//   flaky         fails while committing                                               -> failed
// A job is one queue entry: the first runs, in 5 percent steps every 100 ms (10 ms with
// RUYA_MOCK_FAST=1), through the phases staging (0-19), verifying (20-39), vetting-art (40-54),
// committing (55-69) and installing (70-100); a failing fixture ends in the phase its cause belongs
// to. Cancel works until committing. The job signals go through the same JobBook as the D-Bus
// client's, under job names of its own.
class MockPlayBackend final : public PlayBackend
{
    Q_OBJECT

public:
    explicit MockPlayBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void listSources() override;
    void inspect(const QString &path) override;
    void install(const QString &path, bool adminApproved) override;
    void verify(const QString &appId) override;
    void cancel(const QString &key) override;
    void readDeveloperMode() override;
    void requestDeveloperMode(bool on, bool adminApproved) override;
    void listJobs() override;

    // Tests only.
    void reset();
    // The drive is mounted / unmounted (SourcesChanged follows).
    void setDriveMounted(bool mounted);
    void setDeveloperMode(bool on);
    bool developerMode() const { return m_developerMode; }
    // Installed payload of this app no longer matches its file table: a verify ends invalid-package.
    void corruptInstalled(const QString &appId);
    void setInstalled(const QString &appId, uint build) { m_installed.insert(appId, build); }
    void pauseJobs(bool paused);
    // The running job stands still once it has reported this percent (it then needs pauseJobs(false)).
    void pauseAtPercent(int percent) { m_pauseAt = percent; }
    // The next call of any method answers "failed" (an internal error of the service).
    void failNext() { m_failNext = true; }
    // The service went away: running and queued jobs vanish without a JobFinished.
    void loseService();
    // The service is back: read the sources and the job table again.
    void regainService();
    static QString pathOf(const QString &fixture);

private:
    struct Fixture;
    struct Job
    {
        QString key;
        QString kind; // "install" | "verify"
        QString jobId;
        QString app;
        QString path;
        int percent = 0;
        int failAt = 101;     // percent at which it ends with failStatus
        QString failStatus;
    };

    static const QList<Fixture> &fixtures();
    const Fixture *fixtureAt(const QString &path) const;
    PlayInfo infoOf(const Fixture &f) const;
    QString verdictOf(const Fixture &f) const;
    bool failing(const QString &op, const QString &key);
    void answerLater(const QString &op, const QString &key, const QString &status);
    void startJob(const QString &op, const QString &key, const QString &kind, const QString &app,
                  const QString &path, int failAt, const QString &failStatus);
    void step();
    void finish(const Job &job, const QString &status, const QString &reason = QString());
    static QString phaseAt(int percent);
    QList<StoreJob> jobTable() const;

    QList<Job> m_jobs; // the first runs
    QList<StoreJob> m_finishedJobs;
    QHash<QString, uint> m_installed; // manifest id -> build
    QSet<QString> m_corrupt;
    QTimer m_timer;
    int m_stepMs = 100;
    int m_jobCounter = 0;
    bool m_mounted = true;
    bool m_developerMode = false;
    bool m_paused = false;
    bool m_failNext = false;
    int m_pauseAt = 0;
};
