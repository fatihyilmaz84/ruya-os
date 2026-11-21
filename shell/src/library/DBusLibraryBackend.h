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

private:
    // Calls a Library1 method with args; done gets whether it answered with at least outArgs
    // arguments, and those arguments (a failure is logged with the method's name).
    using Answer = std::function<void(bool ok, const QVariantList &out)>;
    void call(const QString &method, const QVariantList &args, int outArgs, Answer done);

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
