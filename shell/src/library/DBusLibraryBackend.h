#pragma once

#include "LibraryBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

#include <functional>

// Client of org.ruyaos.Library1 (api/dbus/org.ruyaos.Library1.xml) on the system bus, or the
// session bus when RUYA_DBUS=session. The service may start after the shell, so the list is read
// again whenever the name appears.
class DBusLibraryBackend final : public LibraryBackend
{
    Q_OBJECT

public:
    explicit DBusLibraryBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void listItems() override;
    void rescan() override;
    void listRunners() override;
    void getRunnerChoice(const QString &profile, const QString &id) override;
    void setRunnerChoice(const QString &profile, const QString &id, const QString &choice) override;
    void resolveRunner(const QString &id, const QString &choice) override;
    QString activeProfile() const override { return m_activeProfile; }
    void setPreferredInstallation(const QString &profile, const QString &game, const QString &installation) override;
    void linkInstallations(const QString &profile, const QString &a, const QString &b) override;
    void unlinkInstallation(const QString &profile, const QString &installation) override;

private slots:
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);

private:
    // Reads ActiveProfile (at start and whenever the service appears).
    void fetchActive();
    void setActive(const QString &profile);

    // Calls a Library1 method with args; done gets whether it answered with at least outArgs
    // arguments, and those arguments (a failure is logged with the method's name).
    using Answer = std::function<void(bool ok, const QVariantList &out)>;
    void call(const QString &method, const QVariantList &args, int outArgs, Answer done);
    // An installation call (RUY-137): one status string, as installationCallFinished.
    void installationCall(const QString &method, const QString &profile, const QVariantList &args);

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
    QString m_activeProfile;
};
