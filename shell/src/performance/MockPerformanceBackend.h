#pragma once

#include "PerformanceBackend.h"

// An in-memory console whose answer holds every state of the contract:
//   cpu_percent 23.5, gpu_percent 41      supported (the rates: "unavailable" in the first reply,
//                                          which has no reading before it, like the service)
//   ram_used / ram_total 3.2 / 8.0 GB     supported
//   cpu_temp 52                            supported
//   vram_used / vram_total, gpu_temp      unsupported
//   power_w 18.4                           stale (as after a reading that failed: the last
//                                          good value); "unavailable" in the first reply
// Deterministic: the values do not move by themselves. Tests change them with setMetric.
class MockPerformanceBackend final : public PerformanceBackend
{
    Q_OBJECT
public:
    explicit MockPerformanceBackend(QObject *parent = nullptr);
    bool isMock() const override { return true; }
    void refresh() override;

    // Tests only.
    // One metric's state and value from now on.
    void setMetric(const QString &name, const QString &state, double value);
    // Back to the console above, with the next reply the first one again.
    void reset();
    // Replies arrive after `ms` (0: on the next turn of the event loop), with the data as it was
    // when asked; the number still on their way.
    void setReplyDelay(int ms) { m_delay = ms; }
    // From now on every request fails (the service does not answer) until it is switched off.
    void setFailing(bool on) { m_failing = on; }
    int pendingReplies() const { return m_pending; }

private:
    QVariantMap current() const;
    QVariantMap m_metrics;
    bool m_first = true;
    int m_delay = 0;
    int m_pending = 0;
    bool m_failing = false;
};
