#pragma once

#include "UpdateBackend.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusServiceWatcher>

#include <functional>

// Client of org.ruyaos.Update1 (api/dbus/org.ruyaos.Update1.xml) on the system bus, or the
// session bus when RUYA_DBUS=session. The service may start after the shell, so the status is
// read again whenever the name appears; the image job is read with it and then follows
// JobChanged.
class DBusUpdateBackend final : public UpdateBackend
{
    Q_OBJECT

public:
    explicit DBusUpdateBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void check() override;
    void download() override;
    void pauseDownload() override;
    void resumeDownload() override;
    void cancelDownload() override;
    void rollback() override;
    void setChannel(const QString &channel) override;
    void setAutoRestart(bool enabled) override;
    void reportActivity(bool appRunning) override;

private slots:
    void onStatusChanged();
    void onJobChanged(const QDBusMessage &message);

private:
    // Check, Download and Rollback take no argument and answer (status).
    void call(const QString &method, const QString &reportAs, const QVariantList &args = {});
    void refreshStatus();
    void refreshJob();
    void getRecord(const QString &method, int index, const std::function<void(const QVariantMap &)> &deliver,
                   const std::function<void()> &failed);

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
