#pragma once

#include "SessionBackend.h"

#include <QStringList>

#include <functional>
#include <optional>

// In-memory sessions. An app id "org.example.*" is installed; "crashy" is too and exits with
// reason "crashed" shortly after it runs; "nolaunch" is installed but never runs (AppExited
// "launch-failed", exit code -1). Launch goes starting -> running after about 300 ms
// (10 ms with RUYA_MOCK_FAST=1); Stop exits with reason "quit" after about a third of that.
// One app id runs once per profile. The profile check is injected (the Session facade passes
// the mock Profiles list); without one every profile is known.
//
// Freeze/Thaw (T-457) follow ruya-session: only a running app of the signed-in profile (the injected
// ActiveProfile; without one there is no check), a second freeze is "ok" and changes nothing, a stop
// thaws a frozen app first. setFailFreeze / setFailThaw make Freeze / Thaw answer "failed". Every freeze, thaw and stop
// that reaches an app is logged in calls().
//
// InstanceOfPid (T-459): every launched instance has a made-up process id (pidOf, 4001 up), and
// only those name an instance; any other pid is "not-found", 0 or less "invalid".
class MockSessionBackend final : public SessionBackend
{
    Q_OBJECT

public:
    using ProfileCheck = std::function<bool(const QString &)>;
    using ActiveProfile = std::function<std::optional<QString>()>;
    explicit MockSessionBackend(ProfileCheck knownProfile = {}, ActiveProfile activeProfile = {},
                                QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void launch(const QString &appId, const QString &profile) override;
    void stop(const QString &instance) override;
    void freeze(const QString &instance) override;
    void thaw(const QString &instance) override;
    void instanceOfPid(int pid) override;

    void reset();
    void setFailFreeze(bool fail) { m_failFreeze = fail; }
    void setFailThaw(bool fail) { m_failThaw = fail; }
    // InstanceOfPid answers after `ms` instead of at once (T-459).
    void setPidAnswerDelay(int ms) { m_pidDelayMs = ms; }
    QStringList calls() const { return m_calls; }
    // The pid of a launched instance's process (from 4001 up), 0 for an unknown instance.
    int pidOf(const QString &instance) const;

private:
    int indexOf(const QString &instance) const;
    void setRunning(const QString &instance);
    void exitApp(const QString &instance, int code, const QString &reason);
    // The status of a freeze or thaw of `instance` before anything is done.
    QString freezable(const QString &instance) const;
    void setFrozen(int index, bool frozen);

    ProfileCheck m_knownProfile;
    ActiveProfile m_activeProfile;
    QStringList m_calls;
    bool m_failFreeze = false;
    bool m_failThaw = false;
    QList<RunningApp> m_running;
    int m_next = 1;
    int m_startMs = 300;
    int m_pidDelayMs = 0;
};
