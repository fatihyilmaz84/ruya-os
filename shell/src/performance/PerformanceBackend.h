#pragma once

#include "RequestSequence.h"

#include <QObject>
#include <QVariantMap>

// Transport behind the Performance QML singleton: org.ruyaos.Devices1.System.GetPerformance over
// D-Bus (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. The reply is one entry per
// metric, { "cpu_percent": { "state": "supported", "value": 23.5 }, ... }, with the contract's
// states ("supported" | "unsupported" | "unavailable" | "stale"). Results arrive asynchronously.
class PerformanceBackend : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;
    virtual bool isMock() const = 0;
    virtual void refresh() = 0;   // reports the metrics

signals:
    void sampled(const QVariantMap &metrics);
    // The newest request failed (the service did not answer or answered an error): the numbers
    // held from earlier are no longer live (T-452).
    void failed();

protected:
    // Replies can arrive out of order (RequestSequence.h); a failed request counts as an outcome (and says `failed`).
    quint64 beginRequest() { return m_seq.begin(); }
    void fail(quint64 request)
    {
        if (m_seq.accept(request))
            emit failed();
    }
    void deliver(quint64 request, const QVariantMap &metrics)
    {
        if (m_seq.accept(request))
            emit sampled(metrics);
    }

private:
    RequestSequence m_seq;
};
