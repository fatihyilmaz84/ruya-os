#pragma once

#include "SessionBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// QML face of org.ruyaos.Session1: launch an installed app as a profile, stop it, and the list
// of what runs. Backend: RUYA_SERVICES picks it (ServicesChoice.h).
//
// Running records are plain objects: { instance, appId, item, parent, profile, started, state, frozen }.
// `frozen` follows FrozenChanged and `state` becomes "stopping" on AppStopping, both in place; a later
// ListRunning reply replaces the whole list (one computed before a stop can say "running" again).
// `item` is the Library1 item id ("flatpak:<appId>", or "steam:<appid>" for a Steam game) and `parent`
// the instance of the Steam instance a game runs under ("" for every other record), ADR-041.
class Session : public SessionSignals
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QVariantList running READ running NOTIFY runningChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Session(std::unique_ptr<SessionBackend> backend, QObject *parent = nullptr);
    ~Session() override;

    static Session *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList running() const { return m_running; }
    bool isMock() const { return m_backend->isMock(); }

    // Results arrive with launchFinished / stopFinished; the app itself with appStarted.
    Q_INVOKABLE void launch(const QString &appId, const QString &profile);
    // A Library1 item (ADR-041): "flatpak:<id>" is launch(id); the answer comes with launchItemFinished.
    Q_INVOKABLE void launchItem(const QString &item, const QString &profile);
    Q_INVOKABLE void stop(const QString &instance);
    // Force quit (RUY-736, the closing screen): ends the whole run at once. The answer comes with
    // killFinished, the end with appExited (reason "killed").
    Q_INVOKABLE void kill(const QString &instance);
    // The Ruya Hub pauses the game (T-457): results with freezeFinished / thawFinished, the record's
    // `frozen` follows frozenChanged.
    Q_INVOKABLE void freeze(const QString &instance);
    Q_INVOKABLE void thaw(const QString &instance);
    // The running instance the process `pid` belongs to (T-459, the client of a window): the answer
    // comes with instanceOfPidFinished.
    Q_INVOKABLE void instanceOfPid(int pid);
    // The running record of an app for a profile, or an empty object.
    Q_INVOKABLE QVariantMap instanceOf(const QString &appId, const QString &profile) const;

    // Tests only, and only with the mock backend (otherwise a no-op).
    Q_INVOKABLE void mockReset();
    // Freeze answers "failed" from now on (T-457).
    Q_INVOKABLE void mockFailFreeze(bool fail);
    // Thaw answers "failed" from now on and changes nothing (T-457).
    Q_INVOKABLE void mockFailThaw(bool fail);
    // InstanceOfPid answers after `ms` from now on (0 again after mockReset), T-459.
    Q_INVOKABLE void mockDelayPidAnswers(int ms);
    // Stop ends the app after `ms` from now on (a negative number: the default, 0 again after mockReset), T-458.
    Q_INVOKABLE void mockStopDelay(int ms);
    // Stop reports AppExited "killed" but leaves the record listed, from now on (T-458); so does Kill.
    Q_INVOKABLE void mockStubbornStop(bool stubborn);
    // A game that does not close (RUY-736): Stop never ends it by itself, only Kill or the service's
    // backstop (30 s after the Stop, AppExited "killed"), from now on (false again after mockReset).
    Q_INVOKABLE void mockIgnoreStop(bool ignore);
    // Kill answers `status` and does nothing (RUY-736); "" is the normal answer again (and after mockReset).
    Q_INVOKABLE void mockKillAnswer(const QString &status);
    // Stop answers `status` and does nothing (a refused Stop, RUY-1238); "" is the normal answer again (and
    // after mockReset).
    Q_INVOKABLE void mockStopAnswer(const QString &status);
    // The process id the mock gives a launched instance's window client (0 when unknown), T-459.
    Q_INVOKABLE int mockPidOf(const QString &instance) const;
    // A Steam game starts under the running instance `parentInstance` (ADR-041, for B6's tests): a child
    // record with `item` and `parent`, and AppStarted with the parent's app id. Returns the child's instance,
    // "" when the parent is not running or `item` is not "steam:<digits>".
    Q_INVOKABLE QString mockStartChild(const QString &parentInstance, const QString &item);
    // The game ends by itself: AppExited "quit" for the child, with the parent's app id.
    Q_INVOKABLE void mockEndChild(const QString &instance);
    // A Steam game LaunchItem starts from now on is "launch-failed" after `ms` without its scope
    // (ruya-session's 120 s, again after mockReset), RUY-1067.
    Q_INVOKABLE void mockChildLaunchWait(int ms);
    // The system goes down (ruya-session's StopAll, RUY-888), replayed in the service's order (RUY-1235):
    // AppStopping for every run (children first), then the FrozenChanged(false) of each frozen one's thaw;
    // each run ends later with AppExited, as a Stop of it would (mockStopDelay, mockIgnoreStop).
    Q_INVOKABLE void mockStopAll();
    // A ListRunning reply computed now reaches this client after `ms` (RUY-1238): the race of a reply that
    // crosses a stop, whose "running" overwrites the "stopping" AppStopping set until the next refresh.
    Q_INVOKABLE void mockListRunningLate(int ms);
    // "freeze <instance>", "thaw <instance>", "stop <instance>", "kill <instance>" and "forward steam:<appid>"
    // (a Steam game handed to the running Steam) in the order they were asked.
    Q_INVOKABLE QStringList mockCalls() const;

signals:
    // The Session1 signals (launchFinished ... appExited) are SessionSignals', declared once for the backend
    // and this facade (RUY-1242).
    void runningChanged();

private:
    // Sets `key` of the running record of `instance` in place (runningChanged when it changed).
    void setRecordValue(const QString &instance, const QString &key, const QVariant &value);

    std::unique_ptr<SessionBackend> m_backend;
    QVariantList m_running;
};
