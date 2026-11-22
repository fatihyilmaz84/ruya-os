#pragma once

#include "SessionBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Session1 (api/dbus/org.ruyaos.Session1.xml) on the system bus, or the
// session bus when RUYA_DBUS=session. Unverified until ruya-session exists (T-139): it only
// compiles here. The service may start after the shell, so the list is read again whenever the
// name appears.
class DBusSessionBackend final : public SessionBackend
{
    Q_OBJECT

public:
    explicit DBusSessionBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void launch(const QString &appId, const QString &profile) override;
    void launchItem(const QString &item, const QString &profile) override;
    void stop(const QString &instance) override;
    void kill(const QString &instance) override;
    void freeze(const QString &instance) override;
    void thaw(const QString &instance) override;
    void instanceOfPid(int pid) override;

private:
    // Launch or LaunchItem: an id and the profile in, (status, instance) out; `finished` is the signal
    // that carries the answer.
    using LaunchFinished = void (SessionBackend::*)(const QString &, const QString &, const QString &, const QString &);
    void launcher(const QString &method, const QString &id, const QString &profile, LaunchFinished finished);
    // Freeze or Thaw: one string in, the status out (T-457).
    void freezer(const QString &method, const QString &instance);

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
