#pragma once

#include "BatteryBackend.h"

// In-memory batteries: one controller, "Ruya Pad Pro", at 60 % and discharging (reset()); populate()
// fills in a made-up household of devices for screenshots.
class MockBatteryBackend final : public BatteryBackend
{
    Q_OBJECT

public:
    explicit MockBatteryBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;

    // Tests only.
    // percent -1: a device that reports no level (it is not shown). Changes a device (keeping its name and kind unless new ones are given) or adds one: `kind`
    // defaults to "controller", the name to one made from the kind and the id.
    // `family`: a controller's (T-260), only when given.
    void setDevice(const QString &id, int percent, const QString &state, const QString &kind = QString(),
                   const QString &name = QString(), const QString &family = QString(),
                   const QString &address = QString());
    void removeDevice(const QString &id);
    void clear();
    void reset();
    void populate();
    // Replies to refresh() arrive after `ms` (0: at once), with the list as it was when asked; the
    // number of replies still on their way. Lets a test play an old reply landing after a new one.
    void setReplyDelay(int ms) { m_delay = ms; }
    int pendingReplies() const { return m_pending; }

private:
    void publish();

    QList<DeviceBattery> m_list;
    int m_delay = 0;
    int m_pending = 0;
};
