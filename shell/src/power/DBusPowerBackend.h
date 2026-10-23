#pragma once

#include "PowerBackend.h"

#include <QDBusConnection>

// Client of org.freedesktop.login1.Manager on the system bus. Actions are called with
// interactive=false: the polkit rule shipped in the image (50-ruyaos-power.rules) lets the
// shell's user through without a prompt, and anybody else is refused instead of asking.
class DBusPowerBackend final : public PowerBackend
{
    Q_OBJECT

public:
    explicit DBusPowerBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void perform(const QString &action) override;

private:
    QDBusConnection m_bus;
};
