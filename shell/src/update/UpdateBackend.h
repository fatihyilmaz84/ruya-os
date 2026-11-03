#pragma once

#include <QObject>
#include <QString>

// The status record of org.ruyaos.Update1 (api/dbus/org.ruyaos.Update1.xml, "GetStatus").
struct UpdateStatus
{
    QString state = QStringLiteral("idle"); // idle | checking | downloading | staged | up-to-date | failed
    QString current;
    QString available;
    QString staged;
    QString channel = QStringLiteral("stable");
    bool autoRestart = true;
    qint64 lastCheck = 0;
    qint64 restartAt = 0; // unix seconds of the announced automatic restart, 0 = none
    int progress = 0;
    bool rollbackAvailable = false;
    QString error;
};

// Transport behind the Update QML singleton: org.ruyaos.Update1 over D-Bus, or an in-memory mock.
// Results arrive asynchronously through signals.
class UpdateBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0;                       // reports the status
    virtual void check() = 0;
    virtual void download() = 0;
    virtual void rollback() = 0;
    virtual void setChannel(const QString &channel) = 0;
    virtual void setAutoRestart(bool enabled) = 0;
    // Input arrived (the caller limits this to once a minute); appRunning: an app is in front.
    // No reply.
    virtual void reportActivity(bool appRunning) = 0;

signals:
    void statusChanged(const UpdateStatus &status);
    // method: "check" | "download" | "rollback" | "setChannel" | "setAutoRestart"; status: see the XML header
    // ("ok", "busy", "unavailable", "invalid", "forbidden", "failed").
    void requestFinished(const QString &method, const QString &status);
};
