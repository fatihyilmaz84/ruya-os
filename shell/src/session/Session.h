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
// Running records are plain objects: { instance, appId, profile, started, state }.
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
    // The running record of an app for a profile, or an empty object.
    Q_INVOKABLE QVariantMap instanceOf(const QString &appId, const QString &profile) const;

    // Tests only, and only with the mock backend (otherwise a no-op).
    Q_INVOKABLE void mockReset();

signals:
    void runningChanged();
    // status: see api/dbus/org.ruyaos.Session1.xml; `instance` is set on "ok" only.
    void launchFinished(const QString &appId, const QString &profile, const QString &status, const QString &instance);
    void stopFinished(const QString &instance, const QString &status);
    void appStarted(const QString &instance, const QString &appId);
    // reason: "quit" | "crashed" | "killed" | "launch-failed"
    void appExited(const QString &instance, const QString &appId, int exitCode, const QString &reason);

private:
    std::unique_ptr<SessionBackend> m_backend;
    QVariantList m_running;
};
