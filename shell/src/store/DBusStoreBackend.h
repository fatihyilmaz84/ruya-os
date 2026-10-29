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
    void search(const QString &query, bool gamepadOnly, uint limit) override;
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

    // A signal can overtake the reply that names its job. While an Install/Uninstall/Update call
    // is unanswered, signals of unknown jobs are kept and replayed once the reply maps the id.
    struct EarlySignal
    {
        bool finished = false;
        uint percent = 0;
        QString phase;
        QString status;
    };
    void replay(const QString &job, const QString &appId);
    QHash<QString, QList<EarlySignal>> m_early;
    int m_pendingCalls = 0;
};
