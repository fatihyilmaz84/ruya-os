#pragma once

#include "StoreBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>
#include <QHash>

// Client of org.ruyaos.Store1 (api/dbus/org.ruyaos.Store1.xml) on the system bus, or the session
// bus when RUYA_DBUS=session. The service may start after the shell, so the lists are read
// again whenever the name appears. GetApp, Rollback, ListRemotes and AddRemote have no caller
// yet and no method here.
class DBusStoreBackend final : public StoreBackend
{
    Q_OBJECT

public:
    explicit DBusStoreBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void search(const QString &query) override;
    void install(const QString &id) override;
    void uninstall(const QString &id, bool deleteData) override;
    void update(const QString &id) override;

private slots:
    void onJobProgress(const QString &job, uint percent, const QString &phase);
    void onJobFinished(const QString &job, const QString &status);

private:
    // Install, Uninstall and Update all answer (status, job).
    void startJob(const QString &method, const QString &id, const QVariantList &args);

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
    QHash<QString, QString> m_jobApps; // job id -> app id
};
