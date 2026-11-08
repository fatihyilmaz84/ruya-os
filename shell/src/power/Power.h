#pragma once

#include "PowerBackend.h"

#include <QObject>
#include <QQmlEngine>

#include <memory>

// QML face of suspend / restart / power off. Which transport it uses follows RUYA_SERVICES
// like Profiles (mock, or D-Bus to systemd-logind).
class Power : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool canSuspend READ canSuspend NOTIFY capabilitiesChanged)
    // The console may put itself to sleep after idle time (T-202): logind allows suspend AND
    // suspend is known to work on this image (T-166). The mock always says yes; on the image the
    // file /usr/share/ruyaos/suspend-verified (or RUYA_SUSPEND_VERIFIED=1) is what T-166 provides.
    // The Sleep step exists only while this is true.
    Q_PROPERTY(bool sleepAllowed READ sleepAllowed NOTIFY capabilitiesChanged)
    // Suspend is known to work on this image: the marker file above (or the env switch). The mock
    // has it unless a test removes it. Settings -> Power saving shows the Sleep row without it,
    // disabled, saying sleep is not available yet (T-293).
    Q_PROPERTY(bool suspendVerified READ suspendVerified NOTIFY capabilitiesChanged)
    Q_PROPERTY(bool canRestart READ canRestart NOTIFY capabilitiesChanged)
    Q_PROPERTY(bool canPowerOff READ canPowerOff NOTIFY capabilitiesChanged)
    // The last action handed to the backend ("suspend", "restart", "poweroff", or empty).
    // The mock never powers anything off, so tests read this.
    Q_PROPERTY(QString lastAction READ lastAction NOTIFY lastActionChanged)
    Q_PROPERTY(int actionCount READ actionCount NOTIFY lastActionChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Power(std::unique_ptr<PowerBackend> backend, QObject *parent = nullptr);
    ~Power() override;

    static Power *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    // Only "yes" counts: "challenge" would need an interactive prompt the shell never shows.
    bool canSuspend() const { return m_suspend; }
    bool sleepAllowed() const;
    bool suspendVerified() const;
    bool canRestart() const { return m_restart; }
    bool canPowerOff() const { return m_poweroff; }
    QString lastAction() const { return m_lastAction; }
    int actionCount() const { return m_actionCount; }
    bool isMock() const { return m_backend->isMock(); }

    Q_INVOKABLE void suspend();
    Q_INVOKABLE void restart();
    Q_INVOKABLE void powerOff();
    Q_INVOKABLE void refresh();
    // Tests only: narrows what the mock backend allows. Does nothing against logind.
    Q_INVOKABLE void mockSetCapabilities(const QString &suspend, const QString &restart, const QString &poweroff);
    Q_INVOKABLE void mockSetSuspendVerified(bool verified);
    Q_INVOKABLE void mockReset();

signals:
    void capabilitiesChanged();
    void lastActionChanged();
    // The backend finished an action. `ok` is false when logind refused (polkit, no support).
    void done(const QString &action, bool ok, const QString &error);

private:
    void perform(const QString &action);

    std::unique_ptr<PowerBackend> m_backend;
    bool m_suspend = false;
    bool m_restart = false;
    bool m_poweroff = false;
    QString m_lastAction;
    int m_actionCount = 0;
    bool m_mockVerified = true;
};
