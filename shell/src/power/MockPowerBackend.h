#pragma once

#include "PowerBackend.h"

// Records the requested action instead of powering anything off. Every action is allowed
// unless a test narrows it with setCapabilities().
class MockPowerBackend final : public PowerBackend
{
    Q_OBJECT

public:
    explicit MockPowerBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void perform(const QString &action) override;

    // Test hook (reached through Power.mockSetCapabilities).
    void setCapabilities(const QString &suspend, const QString &restart, const QString &poweroff);

private:
    QString m_suspend = QStringLiteral("yes");
    QString m_restart = QStringLiteral("yes");
    QString m_poweroff = QStringLiteral("yes");
};
