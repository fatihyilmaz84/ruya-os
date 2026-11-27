#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QString>

// The signals of org.ruyaos.Session1 as the shell sees them, declared once. SessionBackend (the transport:
// D-Bus or mock) emits them and Session (the QML facade) re-emits them, so both derive from this class and
// Session connects one signal to the same signal of itself: a new Session1 signal is one line here and,
// for a pure forward, one connect in Session.cpp (RUY-1242). Not a QML type of its own (QML_ANONYMOUS): QML
// reaches these signals through Session.
class SessionSignals : public QObject
{
    Q_OBJECT
    QML_ANONYMOUS

public:
    using QObject::QObject;

signals:
    // status: see api/dbus/org.ruyaos.Session1.xml; `instance` is set on "ok" only.
    void launchFinished(const QString &appId, const QString &profile, const QString &status, const QString &instance);
    // LaunchItem's answer, with the statuses of launchFinished.
    void launchItemFinished(const QString &item, const QString &profile, const QString &status, const QString &instance);
    void stopFinished(const QString &instance, const QString &status);
    // status: "ok" | "unknown-instance" | "not-allowed" | "failed"
    void killFinished(const QString &instance, const QString &status);
    // status: "ok" | "invalid" | "not-running" | "not-allowed" | "failed"
    void freezeFinished(const QString &instance, const QString &status);
    void thawFinished(const QString &instance, const QString &status);
    // status: "ok" | "invalid" | "not-found" (or "failed" when the call failed); `instance` on "ok".
    void instanceOfPidFinished(int pid, const QString &status, const QString &instance);
    // The two signals of a record that changes in place: `frozen` after frozenChanged, `state` "stopping" after
    // appStopping (Session1 AppStopping, RUY-1235: whoever asked for the stop, Stop, Kill, the system going
    // down, a parent's Stop or Kill; it comes before the FrozenChanged(false) of the same stop). The facade
    // sends appStopping just before the record changes, so a handler sees what held when the stop began.
    void frozenChanged(const QString &instance, bool frozen);
    void appStopping(const QString &instance, const QString &appId);
    void appStarted(const QString &instance, const QString &appId);
    // reason: "quit" | "crashed" | "killed" | "launch-failed"
    void appExited(const QString &instance, const QString &appId, int exitCode, const QString &reason);
};
