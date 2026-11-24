#include "Performance.h"
#include "ServicesChoice.h"

#include "DBusPerformanceBackend.h"
#include "DeviceSettings.h"
#include "MockPerformanceBackend.h"

#include <QQmlEngine>

Performance::Performance(std::unique_ptr<PerformanceBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &PerformanceBackend::sampled, this, &Performance::apply);
    connect(m_backend.get(), &PerformanceBackend::failed, this, &Performance::markUnavailable);
    m_pollTimer.setInterval(m_intervalMs);
    connect(&m_pollTimer, &QTimer::timeout, this, &Performance::poll);
    m_frameTimer.setInterval(FrameUpdateMs);
    connect(&m_frameTimer, &QTimer::timeout, this, &Performance::updateFrames);
    connect(&m_meter, &FrameMeter::countingChanged, this, [this] {
        if (m_meter.counting())
            m_frameTimer.start();
        else
            m_frameTimer.stop();
        emit countingChanged();
        updateFrames();
    });
    // Nothing is asked for here: only a consumer starts the polling. Except for the measuring
    // scripts (scripts/dell-hub-check.sh, T-455): RUYA_PERF_LOG=1 holds a consumer for the whole
    // run and writes the frame numbers to the journal once per update.
    if (qEnvironmentVariableIsSet("RUYA_PERF_LOG")) {
        setFrameLog(true);
        acquire();
    }
}

Performance::~Performance() = default;

Performance *Performance::create(QQmlEngine *qmlEngine, QJSEngine *)
{
    std::unique_ptr<PerformanceBackend> backend;
    const bool mock = ruya::useMockServices();
    if (mock)
        backend = std::make_unique<MockPerformanceBackend>();
    else
        backend = std::make_unique<DBusPerformanceBackend>();
    auto *performance = new Performance(std::move(backend));
    if (qmlEngine)
        performance->followSettings(qmlEngine->singletonInstance<DeviceSettings *>("RuyaShell", "DeviceSettings"));
    return performance;
}

void Performance::followSettings(DeviceSettings *settings)
{
    if (!settings)
        return;
    setIntervalMs(settings->performanceIntervalMs());
    connect(settings, &DeviceSettings::performanceIntervalMsChanged, this,
            [this, settings] { setIntervalMs(settings->performanceIntervalMs()); });
}

void Performance::setIntervalMs(int ms)
{
    if (!DeviceSettings::isValidPerformanceInterval(ms) || ms == m_intervalMs)
        return;
    m_intervalMs = ms;
    m_pollTimer.setInterval(ms);
    emit intervalMsChanged();
}

void Performance::acquire()
{
    ++m_consumers;
    emit consumersChanged();
    if (m_consumers == 1)
        setRunning();
}

void Performance::release()
{
    if (m_consumers == 0) {
        qWarning("ruya-shell: Performance.release() without a consumer");
        return;
    }
    --m_consumers;
    emit consumersChanged();
    if (m_consumers == 0)
        setRunning();
}

void Performance::setRunning()
{
    const bool on = m_consumers > 0;
    if (on) {
        markUnavailable();   // what was held from before is not live now
        poll();   // the first numbers at once, then every interval
        m_pollTimer.start();
    } else {
        m_pollTimer.stop();
    }
    m_meter.setRunning(on);
}

void Performance::refresh()
{
    if (m_consumers > 0)
        poll();
}

void Performance::poll()
{
    ++m_pollCount;
    emit pollCountChanged();
    m_backend->refresh();
}

void Performance::apply(const QVariantMap &metrics)
{
    // A reply that lands after the last consumer closed is still the newest numbers: keep it.
    if (m_valid && m_fresh && metrics == m_metrics)
        return;
    m_metrics = metrics;
    m_valid = true;
    m_fresh = true;
    emit metricsChanged();
}

void Performance::markUnavailable()
{
    if (!m_valid || !m_fresh)
        return;
    m_fresh = false;
    for (auto it = m_metrics.begin(); it != m_metrics.end(); ++it) {
        const QVariantMap entry = it.value().toMap();
        if (entry.value(QStringLiteral("state")).toString() == QLatin1String("unsupported"))
            continue;   // a console without a source stays without one
        it.value() = QVariantMap { { QStringLiteral("state"), QStringLiteral("unavailable") },
                                   { QStringLiteral("value"), 0.0 } };
    }
    emit metricsChanged();
}

QString Performance::stateOf(const QString &name) const
{
    const QVariantMap entry = m_metrics.value(name).toMap();
    const QString state = entry.value(QStringLiteral("state")).toString();
    return state.isEmpty() ? QStringLiteral("unavailable") : state;
}

double Performance::valueOf(const QString &name) const
{
    return m_metrics.value(name).toMap().value(QStringLiteral("value")).toDouble();
}

void Performance::setFrameSource(QObject *source)
{
    if (source == m_meter.source())
        return;
    m_meter.setSource(source);
    emit frameSourceChanged();
    updateFrames();
}

void Performance::setFrameWindow(QObject *window)
{
    if (window == m_meter.window())
        return;
    m_meter.setWindow(window);
    emit frameWindowChanged();
    updateFrames();
}

QString Performance::frameState() const
{
    if (!m_meter.window())
        return QStringLiteral("unsupported");
    return m_meter.counting() && m_stats.full ? QStringLiteral("supported") : QStringLiteral("unavailable");
}

void Performance::setFrameLog(bool on)
{
    m_logFrames = on;
    m_updatesSinceIntervals = 0;
    m_meter.setRecordIntervals(on);
}

QString Performance::takeFrameIntervals()
{
    QStringList parts;
    for (double ms : m_meter.takeIntervalsMs())
        parts.append(QString::number(ms, 'f', 2));
    return parts.join(QLatin1Char(','));
}

QString Performance::frameLogLine() const
{
    return QStringLiteral("ruya-shell: perf-frames fps=%1 full=%2 commits=%3 meanMs=%4 p99Ms=%5 low1=%6 low01=%7")
        .arg(m_stats.frames)
        .arg(m_stats.full ? 1 : 0)
        .arg(m_stats.commits)
        .arg(m_stats.meanMs, 0, 'f', 1)
        .arg(m_stats.p99Ms, 0, 'f', 1)
        .arg(fpsLow1())
        .arg(fpsLow01());
}

void Performance::updateFrames()
{
    m_stats = m_meter.stats();
    if (m_logFrames && m_meter.counting()) {
        qInfo("%s", qPrintable(frameLogLine()));
        // One line a second with every interval of that second (a measuring script's p50/p99/p99.9).
        if (++m_updatesSinceIntervals >= UpdatesPerSecond) {
            m_updatesSinceIntervals = 0;
            const QString intervals = takeFrameIntervals();
            if (!intervals.isEmpty())
                qInfo("ruya-shell: perf-frame-intervals %s", qPrintable(intervals));
        }
    }
    emit framesChanged();
}

void Performance::mockSet(const QString &name, const QString &state, double value)
{
    if (auto *mock = qobject_cast<MockPerformanceBackend *>(m_backend.get()))
        mock->setMetric(name, state, value);
}

void Performance::mockReset()
{
    if (auto *mock = qobject_cast<MockPerformanceBackend *>(m_backend.get()))
        mock->reset();
}

void Performance::mockFail(bool on)
{
    if (auto *mock = qobject_cast<MockPerformanceBackend *>(m_backend.get()))
        mock->setFailing(on);
}

void Performance::mockReplyDelay(int ms)
{
    if (auto *mock = qobject_cast<MockPerformanceBackend *>(m_backend.get()))
        mock->setReplyDelay(ms);
}

int Performance::mockPendingReplies() const
{
    if (auto *mock = qobject_cast<MockPerformanceBackend *>(m_backend.get()))
        return mock->pendingReplies();
    return 0;
}

void Performance::fakeFrameClockMs(double ms)
{
    m_meter.setFakeNowMs(ms);
}

// ---------------------------------------------------------------------------------------------

PerformanceConsumer::PerformanceConsumer(QObject *parent)
    : QObject(parent)
{
}

PerformanceConsumer::~PerformanceConsumer()
{
    if (m_holding && m_performance)
        m_performance->release();
}

void PerformanceConsumer::componentComplete()
{
    if (QQmlEngine *engine = qmlEngine(this))
        m_performance = engine->singletonInstance<Performance *>("RuyaShell", "Performance");
    m_complete = true;
    sync();
}

void PerformanceConsumer::setActive(bool on)
{
    if (on == m_active)
        return;
    m_active = on;
    emit activeChanged();
    sync();
}

void PerformanceConsumer::sync()
{
    const bool hold = m_complete && m_active && m_performance;
    if (hold == m_holding)
        return;
    m_holding = hold;
    if (hold)
        m_performance->acquire();
    else if (m_performance)
        m_performance->release();
}
