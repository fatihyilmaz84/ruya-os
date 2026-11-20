#pragma once

#include "PlayBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Play1 (api/dbus/org.ruyaos.Play1.xml) on the system bus, or the session bus
// when RUYA_DBUS=session. The service (ruya-play, RUY-100) is not built yet, so nothing answers
// today: the Play facade then stays unavailable. The service may start after the shell, so the
// sources and the job table are read again whenever the name appears.
class DBusPlayBackend final : public PlayBackend
{
    Q_OBJECT

public:
    explicit DBusPlayBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void listSources() override;
    void inspect(const QString &path) override;
    void install(const QString &path, bool adminApproved) override;
    void verify(const QString &appId) override;
    void remove(const QString &appId, bool adminApproved) override;
    void cancel(const QString &key) override;
    void readDeveloperMode() override;
    void requestDeveloperMode(bool on, bool adminApproved) override;
    void listJobs() override;

private slots:
    void onJobProgress(const QString &job, uint percent, const QString &phase);
    void onJobFinished(const QString &job, const QString &status);
    void onDeveloperModeChanged(bool on);

private:
    // Install, Verify and Remove all answer (status, job).
    void startJob(const QString &op, const QString &method, const QString &key, const QVariantList &args);

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
