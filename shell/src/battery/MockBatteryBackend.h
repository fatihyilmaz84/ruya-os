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
    // Replies to refresh() arrive after `ms` (0: at once), with the list as it was when asked; the
    // number of replies still on their way. Lets a test play an old reply landing after a new one.
    void setReplyDelay(int ms) { m_delay = ms; }
    int pendingReplies() const { return m_pending; }

private:
    void publish();

    QList<ControllerBattery> m_list;
    int m_delay = 0;
    int m_pending = 0;
};
