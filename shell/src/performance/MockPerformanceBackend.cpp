#include "MockPerformanceBackend.h"

#include <QTimer>

namespace {
QVariantMap metric(const QString &state, double value)
{
    return { { QStringLiteral("state"), state }, { QStringLiteral("value"), value } };
}

const QString Supported = QStringLiteral("supported");
const QString Unsupported = QStringLiteral("unsupported");
const QString Unavailable = QStringLiteral("unavailable");
const QString Stale = QStringLiteral("stale");

// The metrics that are rates: the service has no number for them in the first reply.
const QStringList Rates = { QStringLiteral("cpu_percent"), QStringLiteral("gpu_percent"), QStringLiteral("power_w") };
} // namespace

MockPerformanceBackend::MockPerformanceBackend(QObject *parent)
    : PerformanceBackend(parent)
{
    reset();
}

void MockPerformanceBackend::reset()
{
    m_metrics = {
        { QStringLiteral("cpu_percent"), metric(Supported, 23.5) },
        { QStringLiteral("ram_used"), metric(Supported, 3.2e9) },
        { QStringLiteral("ram_total"), metric(Supported, 8.0e9) },
        { QStringLiteral("gpu_percent"), metric(Supported, 41.0) },
        { QStringLiteral("vram_used"), metric(Unsupported, 0.0) },
        { QStringLiteral("vram_total"), metric(Unsupported, 0.0) },
        { QStringLiteral("cpu_temp"), metric(Supported, 52.0) },
        { QStringLiteral("gpu_temp"), metric(Unsupported, 0.0) },
        { QStringLiteral("power_w"), metric(Stale, 18.4) },
    };
    m_first = true;
}

void MockPerformanceBackend::setMetric(const QString &name, const QString &state, double value)
{
    m_metrics.insert(name, metric(state, value));
}

QVariantMap MockPerformanceBackend::current() const
{
    QVariantMap out = m_metrics;
    if (m_first) {
        for (const QString &name : Rates)
            out.insert(name, metric(Unavailable, 0.0));
    }
    return out;
}

void MockPerformanceBackend::refresh()
{
    const quint64 request = beginRequest();
    const QVariantMap reply = current();
    m_first = false;
    ++m_pending;
    QTimer::singleShot(m_delay, this, [this, request, reply] {
        --m_pending;
        deliver(request, reply);
    });
}
