#pragma once

#include "ThermalBackend.h"

// In-memory sensors: a processor at 41 degrees, a drive at 38 and a fan at 1820 rpm, all normal.
class MockThermalBackend final : public ThermalBackend
{
    Q_OBJECT

public:
    explicit MockThermalBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;

    // Tests only.
    // Sets a sensor (adding it when the id is new; the highest value is kept as max_seen).
    void setSensor(const QString &id, const QString &cls, double value, const QString &level);
    void removeSensor(const QString &id);
    void clear();
    void reset();
    // Replies to refresh() arrive after `ms` (0: at once), with the list as it was when asked; the
    // number of replies still on their way. Lets a test play an old reply landing after a new one.
    void setReplyDelay(int ms) { m_delay = ms; }
    int pendingReplies() const { return m_pending; }

private:
    void publish();

    QList<ThermalSensor> m_list;
    int m_delay = 0;
    int m_pending = 0;
};
