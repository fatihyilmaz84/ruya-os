#pragma once

#include "UpdateBackend.h"

#include <QTimer>

// In-memory Update1: a check finds one newer image (once), a download stages it as the image job
// (RUY-29): 10 % a step up to 90 % while "bytes" arrive (phase "download"), then 95 % (phase
// "install"), then staged at 100 %. Steps take 100 ms (10 ms with RUYA_MOCK_FAST=1).
// Follows the rules the real service has: no Download without a found update (or a paused job),
// busy while a check or download runs, Rollback only with rollback_available, "forbidden" for
// Rollback, SetChannel and SetAutoRestart when the caller is not an admin (test hook);
// PauseDownload, ResumeDownload and CancelDownload answer "wrong-state" without a job to act on
// and "unsupported" during the install; SetChannel and Rollback cancel a paused job.
// ReportActivity is counted, and it calls off an announced restart like the service does
// (restart_at back to 0).
class MockUpdateBackend final : public UpdateBackend
{
    Q_OBJECT

public:
    explicit MockUpdateBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    // Tests only: ask for the status, but deliver the reply (a snapshot of now) after ms.
    void refreshDelayed(int ms) { publishAfter(ms); }
    int pendingReplies() const { return m_pending; }
    void check() override;
    void download() override;
    void pauseDownload() override;
    void resumeDownload() override;
    void cancelDownload() override;
    void rollback() override;
    void setChannel(const QString &channel) override;
    void setAutoRestart(bool enabled) override;
    void reportActivity(bool appRunning) override;

    // Test hooks (reached through Update.mock*).
    void reset();
    void setUpdateExists(bool exists) { m_updateExists = exists; }
    void setRollbackAvailable(bool available);
    // The next check fails: state "failed" and the reply "failed".
    void setFailNext(bool fail) { m_failNext = fail; }
    // The download stands still at this percent until resume() (-1: never). A test hold of the
    // mock's own steps, not PauseDownload: the job keeps running.
    void setPauseAt(int percent) { m_pauseAt = percent; }
    void resume();
    int rollbackCount() const { return m_rollbackCount; }
    int activityCount() const { return m_activityCount; }
    bool lastActivityAppRunning() const { return m_lastAppRunning; }
    // The active profile is not an admin: Rollback and SetChannel answer "forbidden".
    void setCallerIsAdmin(bool admin) { m_callerIsAdmin = admin; }
    // The service announces a restart at this unix time (0: none), as the schedule does.
    void announceRestart(qint64 restartAt);

private:
    bool isRunning() const;
    void finish(const QString &method, const QString &status);
    void publish();
    void publishAfter(int ms);
    void step();
    // The image job.
    QVariantMap jobRecord() const;
    void publishJob();
    void startDownload();
    void endJob(const QString &status);
    void cancelPausedJob();

    UpdateStatus m_status;
    QTimer m_timer;
    int m_stepMs = 100;
    int m_checkTicks = 0;
    int m_pending = 0; // status replies not delivered yet
    bool m_updateExists = true;
    bool m_failNext = false;
    int m_pauseAt = -1;
    bool m_held = false;
    int m_rollbackCount = 0;
    int m_activityCount = 0;
    bool m_lastAppRunning = false;
    bool m_callerIsAdmin = true;
    // The image job; m_jobState "" = none since the start.
    QString m_jobId;
    QString m_jobVersion;
    QString m_jobState; // running | paused | finished
    QString m_jobStatus;
    QString m_jobPhase = QStringLiteral("download");
    qint64 m_jobStarted = 0;
    qint64 m_jobFinished = 0;
};
