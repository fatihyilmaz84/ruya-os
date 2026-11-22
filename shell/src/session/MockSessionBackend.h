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
// A profile that leaves (T-165) has its apps frozen, as ruya-session does on Profiles1's ActiveProfile: the
// facade calls activeProfileChanged() on every change of Profiles.activeProfile, and every running app of the
// profile that was signed in before is frozen (logged "freeze <instance>", FrozenChanged follows; no
// freezeFinished, nobody called Freeze). An app frozen already is not asked again; with setFailFreeze the
// freeze fails and the app keeps running. Nothing is thawed at a sign-in: the shell's HubPause sweep does that.
//
// Stop (T-458): the app exits after a third of the start time unless setStopDelay says otherwise;
// setStubbornStop makes it report AppExited "killed" after that delay while the record stays listed.
// setIgnoreStop (RUY-736) is a game that does not close: Stop leaves it running ("stopping") until Kill or
// the backstop (BackstopMs after the Stop, as ruya-session's STOP_GRACE) ends it with AppExited "killed".
// Kill (RUY-736) follows ruya-session: "unknown-instance" for an unknown or empty name, "not-allowed" for
// another profile's app (the injected ActiveProfile), else "ok" and AppExited "killed" at once (with
// setStubbornStop the record stays listed); a frozen app is not thawed first. setKillAnswer makes it
// answer a status and do nothing.
//
// InstanceOfPid (T-459): every launched instance has a made-up process id (pidOf, 4001 up), and
// only those name an instance; any other pid is "not-found", 0 or less "invalid".
//
// Items and children (ADR-041, RUY-1051): every launched record has item "flatpak:<appId>" and parent "".
// LaunchItem follows ruya-session: "flatpak:<id>" is Launch(id), "steam:<digits>" is "failed" (until
// RUY-1052), anything else "invalid". startChild is the seam for a Steam game: a running child record
// under a running instance (item "steam:<appid>", parent that instance, the parent's app id and profile),
// announced with AppStarted; endChild ends it with AppExited "quit". Stop on a parent ends its children
// first ("stop <child>" logged before "stop <parent>").
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
    void launchItem(const QString &item, const QString &profile) override;
    void stop(const QString &instance) override;
    void kill(const QString &instance) override;
    void freeze(const QString &instance) override;
    void thaw(const QString &instance) override;
    void instanceOfPid(int pid) override;

    void reset();
    // The signed-in profile changed (T-165): the apps of the one before are frozen.
    void activeProfileChanged();
    void setFailFreeze(bool fail) { m_failFreeze = fail; }
    void setFailThaw(bool fail) { m_failThaw = fail; }
    // InstanceOfPid answers after `ms` instead of at once (T-459).
    void setPidAnswerDelay(int ms) { m_pidDelayMs = ms; }
    // Stop takes `ms` to end the app (negative: the default, a third of the start time), T-458.
    void setStopDelay(int ms) { m_stopDelayMs = ms; }
    // A stopped app is reported "killed" but stays in the running list (T-458).
    void setStubbornStop(bool stubborn) { m_stubbornStop = stubborn; }
    // Stop does not end the app; only Kill or the backstop does (RUY-736).
    void setIgnoreStop(bool ignore) { m_ignoreStop = ignore; }
    // Kill answers `status` and changes nothing ("": the normal answer), RUY-736.
    void setKillAnswer(const QString &status) { m_killAnswer = status; }
    // ruya-session's STOP_GRACE: an ignored Stop is killed this long after it (RUY-736).
    static constexpr int BackstopMs = 30000;
    QStringList calls() const { return m_calls; }
    // The pid of a launched instance's process (from 4001 up), 0 for an unknown instance.
    int pidOf(const QString &instance) const;
    // A Steam game `item` starts under the running instance `parentInstance`; its instance, or "" (ADR-041).
    QString startChild(const QString &parentInstance, const QString &item);
    // A child ends by itself (AppExited "quit"); nothing for any other instance.
    void endChild(const QString &instance);

private:
    int indexOf(const QString &instance) const;
    // Launch's checks and start: the status, and the new instance on "ok".
    QString start(const QString &appId, const QString &profile, QString *instance);
    // The instances whose parent is `instance`.
    QStringList childrenOf(const QString &instance) const;
    void setRunning(const QString &instance);
    void exitApp(const QString &instance, int code, const QString &reason);
    // The status of a freeze or thaw of `instance` before anything is done.
    QString freezable(const QString &instance) const;
    void setFrozen(int index, bool frozen);

    ProfileCheck m_knownProfile;
    ActiveProfile m_activeProfile;
    // The signed-in profile at the last activeProfileChanged() (or reset), "" when locked.
    QString m_lastActive;
    QStringList m_calls;
    bool m_failFreeze = false;
    bool m_failThaw = false;
    QList<RunningApp> m_running;
    int m_next = 1;
    int m_startMs = 300;
    int m_pidDelayMs = 0;
    int m_stopDelayMs = -1;
    bool m_stubbornStop = false;
    bool m_ignoreStop = false;
    QString m_killAnswer;
};
