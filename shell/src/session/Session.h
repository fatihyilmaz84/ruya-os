#pragma once

#include "SessionBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// QML face of org.ruyaos.Session1: launch an installed app as a profile, stop it, and the list
// of what runs. Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (ruya-session,
// T-139) and the mock elsewhere, like Store and Profiles.
//
// Running records are plain objects: { instance, appId, profile, started, state, frozen }.
class Session : public QObject
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
    Q_INVOKABLE void stop(const QString &instance);
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
    // The process id the mock gives a launched instance's window client (0 when unknown), T-459.
    Q_INVOKABLE int mockPidOf(const QString &instance) const;
    // "freeze <instance>", "thaw <instance>", "stop <instance>" in the order they were asked.
    Q_INVOKABLE QStringList mockCalls() const;

signals:
    void runningChanged();
    // status: see api/dbus/org.ruyaos.Session1.xml; `instance` is set on "ok" only.
    void launchFinished(const QString &appId, const QString &profile, const QString &status, const QString &instance);
    void stopFinished(const QString &instance, const QString &status);
    void freezeFinished(const QString &instance, const QString &status);
    void thawFinished(const QString &instance, const QString &status);
    void frozenChanged(const QString &instance, bool frozen);
    // status: "ok" | "invalid" | "not-found" | "failed"; `instance` is set on "ok" only.
    void instanceOfPidFinished(int pid, const QString &status, const QString &instance);
    void appStarted(const QString &instance, const QString &appId);
    // reason: "quit" | "crashed" | "killed" | "launch-failed"
    void appExited(const QString &instance, const QString &appId, int exitCode, const QString &reason);

private:
    std::unique_ptr<SessionBackend> m_backend;
    QVariantList m_running;
};
