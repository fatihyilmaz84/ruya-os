#pragma once

#include "DisplayBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>
#include <QVariantMap>

// Client of org.ruyaos.Devices1.Display (api/dbus/org.ruyaos.Devices1.xml) on the system bus, or the
// session bus when RUYA_DBUS=session. The service may start after the shell, so the state is read
// again whenever the name appears. Unverified: only a VM run of ruya-devices proves it.
class DBusDisplayBackend final : public DisplayBackend
{
    Q_OBJECT

public:
    explicit DBusDisplayBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void setMode(const QString &output, uint width, uint height, uint refreshMhz) override;
    void keep() override;
    void revert() override;
    void setUiScale(int percent) override;
    void resetSettings() override;
    void takeFallbackNotice() override;
    void refreshBrightness() override;
    void setBrightness(int percent) override;
    void restartShell() override;

private slots:
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);

private:
    // A method that answers one status string.
    void callStatus(const QString &method, const QVariantList &args, void (DisplayBackend::*done)(const QString &));

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
