#pragma once

#include "UpdateBackend.h"

#include <QTimer>

// In-memory Update1: a check finds one newer image (once), a download stages it in steps of
// 10 %, a rollback stages the previous image. Steps take 100 ms (10 ms with RUYA_MOCK_FAST=1).
// Follows the rules the real service will have: no Download without a found update, busy
// while a check or download runs, Rollback only with rollback_available.
class MockUpdateBackend final : public UpdateBackend
{
    Q_OBJECT

public:
    explicit MockUpdateBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void check() override;
    void download() override;
    void rollback() override;
    void setChannel(const QString &channel) override;

    // Test hooks (reached through Update.mock*).
    void reset();
    void setUpdateExists(bool exists) { m_updateExists = exists; }
    void setRollbackAvailable(bool available);
    // The next check fails: state "failed" and the reply "failed".
    void setFailNext(bool fail) { m_failNext = fail; }
    // The download waits at this percent until resume() (-1: no pause).
    void setPauseAt(int percent) { m_pauseAt = percent; }
    void resume();
    int rollbackCount() const { return m_rollbackCount; }

private:
    bool isRunning() const;
    void finish(const QString &method, const QString &status);
    void publish();
    void step();

    UpdateStatus m_status;
    QTimer m_timer;
    int m_stepMs = 100;
    int m_checkTicks = 0;
    bool m_updateExists = true;
    bool m_failNext = false;
    int m_pauseAt = -1;
    bool m_paused = false;
    int m_rollbackCount = 0;
};
