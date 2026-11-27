#pragma once

#include "SessionSignals.h"

#include <QList>
#include <QString>
#include <QVariantMap>

// One running-app record of org.ruyaos.Session1 (api/dbus/org.ruyaos.Session1.xml, "Running record").
struct RunningApp
{
    QString instance; // opaque, chosen by the service
    QString appId; // the Flatpak app id (a Steam child: Steam's)
    QString item; // the Library1 item id (ADR-041): "flatpak:<appId>", or "steam:<appid>" for a Steam child
    QString parent; // the parent's instance for a child instance, else ""
    QString profile;
    qint64 started = 0; // unix seconds
    QString state = QStringLiteral("starting"); // "starting" | "running" | "stopping"
    bool frozen = false; // frozen by Freeze (T-457)
    int pid = 0; // the mock only: the process id its window's client has (T-459)

    // The record as QML sees it (camelCase keys).
    QVariantMap toVariant() const
    {
        return {
            {QStringLiteral("instance"), instance},
            {QStringLiteral("appId"), appId},
            {QStringLiteral("item"), item},
            {QStringLiteral("parent"), parent},
            {QStringLiteral("profile"), profile},
            {QStringLiteral("started"), started},
            {QStringLiteral("state"), state},
            {QStringLiteral("frozen"), frozen},
        };
    }
};

// Transport behind the Session QML singleton: org.ruyaos.Session1 over D-Bus, or an in-memory mock.
// Results arrive asynchronously through signals.
class SessionBackend : public SessionSignals
{
    Q_OBJECT

public:
    using SessionSignals::SessionSignals;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0; // reports the running list
    virtual void launch(const QString &appId, const QString &profile) = 0;
    // A Library1 item (ADR-041, RUY-1051): "flatpak:<id>" is launch(id); a Steam game answers "failed"
    // until RUY-1052. The answer comes with launchItemFinished.
    virtual void launchItem(const QString &item, const QString &profile) = 0;
    virtual void stop(const QString &instance) = 0;
    // Force quit (RUY-736): SIGKILL to the whole run; AppExited "killed" follows.
    virtual void kill(const QString &instance) = 0;
    // The Ruya Hub pauses the game (T-457): the cgroup freezer of the app's units.
    virtual void freeze(const QString &instance) = 0;
    virtual void thaw(const QString &instance) = 0;
    // The running instance a process (a window's client) belongs to (T-459).
    virtual void instanceOfPid(int pid) = 0;

signals:
    // The list of running apps (the Session1 signals are SessionSignals').
    void runningListed(const QList<RunningApp> &apps);
};
