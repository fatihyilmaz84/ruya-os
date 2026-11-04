#pragma once

#include "BatteryBackend.h"

// In-memory batteries: one controller, "Ruya Pad Pro", at 60 % and discharging.
class MockBatteryBackend final : public BatteryBackend
{
    Q_OBJECT

public:
    explicit MockBatteryBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;

    // Tests only.
    // Changes a controller (keeping its name) or adds one named after its id.
    void setController(const QString &id, int percent, const QString &state);
    void removeController(const QString &id);
    void clear();
    void reset();

private:
    QList<ControllerBattery> m_list;
};
