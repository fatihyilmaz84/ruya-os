#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

// One running-app record of org.ruyaos.Session1 (api/dbus/org.ruyaos.Session1.xml, "Running record").
struct RunningApp
{
    QString instance; // opaque, chosen by the service
    QString appId;
    QString profile;
    qint64 started = 0; // unix seconds
    QString state = QStringLiteral("starting"); // "starting" | "running" | "stopping"

    // The record as QML sees it (camelCase keys).
    QVariantMap toVariant() const
    {
        return {
            {QStringLiteral("instance"), instance},
            {QStringLiteral("appId"), appId},
            {QStringLiteral("profile"), profile},
            {QStringLiteral("started"), started},
            {QStringLiteral("state"), state},
        };
    }
};

// Transport behind the Session QML singleton: org.ruyaos.Session1 over D-Bus, or an in-memory mock.
// Results arrive asynchronously through signals.
class SessionBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0; // reports the running list
    virtual void launch(const QString &appId, const QString &profile) = 0;
    virtual void stop(const QString &instance) = 0;

signals:
    void runningListed(const QList<RunningApp> &apps);
    // status: see the XML; `instance` is set on "ok" only.
    void launchFinished(const QString &appId, const QString &profile, const QString &status, const QString &instance);
    void stopFinished(const QString &instance, const QString &status);
    void appStarted(const QString &instance, const QString &appId);
    // reason: "quit" | "crashed" | "killed" | "launch-failed"
    void appExited(const QString &instance, const QString &appId, int exitCode, const QString &reason);
};
