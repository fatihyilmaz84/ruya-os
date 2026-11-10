#pragma once

#include "FrameMeter.h"
#include "PerformanceBackend.h"

#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QQmlParserStatus>
#include <QTimer>
#include <QVariantMap>

#include <memory>

class DeviceSettings;

// QML face of the performance numbers (T-451, ADR-033 point 4) for the Ruya Hub's Performance
// panel (T-452): the kernel's metrics from org.ruyaos.Devices1.System.GetPerformance, and the FPS
// and frame time of the app in front, which the compositor measures (FrameMeter).
//
// Nothing runs while nobody looks: the service is asked only while at least one consumer is open
// (`PerformanceConsumer { active: ... }`, or acquire()/release()), every `intervalMs`
// (DeviceSettings.performanceIntervalMs, 500-5000, default 1000), and the frame meter is connected
// to the app surface and the window only then. Compositor.qml sets `frameWindow` (the shell's
// window) and `frameSource` (the surface of the app in front, null when none); without a
// compositor (the Windows host, the tests) they stay null unless a test sets stand-ins.
//
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (ruya-devices) and the mock
// elsewhere, like SystemDetails.
class Performance : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    // { "cpu_percent": { "state": "supported", "value": 23.5 }, ... } (the names and states of the
    // XML); empty until the first reply. stateOf()/valueOf() answer for a name not (yet) there.
    Q_PROPERTY(QVariantMap metrics READ metrics NOTIFY metricsChanged)
    Q_PROPERTY(bool valid READ valid NOTIFY metricsChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)
    Q_PROPERTY(int consumers READ consumers NOTIFY consumersChanged)
    // The service is being asked (a consumer is open).
    Q_PROPERTY(bool polling READ polling NOTIFY consumersChanged)
    // How many times the service was asked since the start (tests read it).
    Q_PROPERTY(int pollCount READ pollCount NOTIFY pollCountChanged)
    Q_PROPERTY(int intervalMs READ intervalMs NOTIFY intervalMsChanged)

    // Frames of the app in front.
    Q_PROPERTY(QObject *frameSource READ frameSource WRITE setFrameSource NOTIFY frameSourceChanged)
    Q_PROPERTY(QObject *frameWindow READ frameWindow WRITE setFrameWindow NOTIFY frameWindowChanged)
    // The meter is connected (a consumer is open and both are set).
    Q_PROPERTY(bool counting READ counting NOTIFY countingChanged)
    // Commits the meter has seen since the start; does not move while it is not counting.
    Q_PROPERTY(int commitsSeen READ commitsSeen NOTIFY framesChanged)
    // "supported" (a whole second measured), "unavailable" (no app in front, or less than a second
    // since counting started: "Measuring..."), "unsupported" (no compositor window).
    Q_PROPERTY(QString frameState READ frameState NOTIFY framesChanged)
    // Presented frames with new app content in the last second.
    Q_PROPERTY(int fps READ fps NOTIFY framesChanged)
    // Mean and 99th percentile frame time over the last second, ms; -1 without an interval.
    Q_PROPERTY(double frameTimeMs READ frameTimeMs NOTIFY framesChanged)
    Q_PROPERTY(double frameTimeP99Ms READ frameTimeP99Ms NOTIFY framesChanged)
    // The app's commits in the last second (more than fps when it draws faster than the display).
    Q_PROPERTY(int commitsPerSecond READ commitsPerSecond NOTIFY framesChanged)

public:
    static constexpr int FrameUpdateMs = 250;

    explicit Performance(std::unique_ptr<PerformanceBackend> backend, QObject *parent = nullptr);
    ~Performance() override;
    static Performance *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantMap metrics() const { return m_metrics; }
    bool valid() const { return m_valid; }
    bool isMock() const { return m_backend->isMock(); }
    int consumers() const { return m_consumers; }
    bool polling() const { return m_consumers > 0; }
    int pollCount() const { return m_pollCount; }
    int intervalMs() const { return m_intervalMs; }
    void setIntervalMs(int ms);
    // Follows DeviceSettings.performanceIntervalMs (create() connects it).
    void followSettings(DeviceSettings *settings);

    QObject *frameSource() const { return m_meter.source(); }
    void setFrameSource(QObject *source);
    QObject *frameWindow() const { return m_meter.window(); }
    void setFrameWindow(QObject *window);
    bool counting() const { return m_meter.counting(); }
    int commitsSeen() const { return m_meter.commitsSeen(); }
    QString frameState() const;
    int fps() const { return m_stats.frames; }
    double frameTimeMs() const { return m_stats.meanMs; }
    double frameTimeP99Ms() const { return m_stats.p99Ms; }
    int commitsPerSecond() const { return m_stats.commits; }

    // A consumer opens and closes (PerformanceConsumer does this; balanced calls only).
    Q_INVOKABLE void acquire();
    Q_INVOKABLE void release();
    // "unavailable" / 0 for a name the last reply did not carry.
    Q_INVOKABLE QString stateOf(const QString &name) const;
    Q_INVOKABLE double valueOf(const QString &name) const;
    // Asks the service now, outside the interval; only while a consumer is open (no-op otherwise).
    Q_INVOKABLE void refresh();
    // Recomputes the frame numbers now (the frame timer does it every FrameUpdateMs).
    Q_INVOKABLE void updateFrames();

    // Tests only, and only with the mock backend (otherwise no-ops).
    Q_INVOKABLE void mockSet(const QString &name, const QString &state, double value);
    Q_INVOKABLE void mockReset();
    Q_INVOKABLE void mockReplyDelay(int ms);
    Q_INVOKABLE int mockPendingReplies() const;
    // The frame meter's clock in ms (a test clock); negative: the real clock again.
    Q_INVOKABLE void fakeFrameClockMs(double ms);

signals:
    void metricsChanged();
    void consumersChanged();
    void pollCountChanged();
    void intervalMsChanged();
    void frameSourceChanged();
    void frameWindowChanged();
    void countingChanged();
    void framesChanged();

private:
    void apply(const QVariantMap &metrics);
    void poll();
    void setRunning();

    std::unique_ptr<PerformanceBackend> m_backend;
    QVariantMap m_metrics;
    bool m_valid = false;
    int m_consumers = 0;
    int m_pollCount = 0;
    int m_intervalMs = 1000;
    QTimer m_pollTimer;
    QTimer m_frameTimer;
    FrameMeter m_meter;
    FrameMeter::Stats m_stats;
};

// Declares that a Performance view is open while `active` (default true) and the item exists:
// T-452's panel holds one, so the service is asked and the frames counted only then.
class PerformanceConsumer : public QObject, public QQmlParserStatus
{
    Q_OBJECT
    QML_ELEMENT
    Q_INTERFACES(QQmlParserStatus)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)

public:
    explicit PerformanceConsumer(QObject *parent = nullptr);
    ~PerformanceConsumer() override;

    bool active() const { return m_active; }
    void setActive(bool on);

    void classBegin() override {}
    void componentComplete() override;

signals:
    void activeChanged();

private:
    void sync();
    QPointer<Performance> m_performance;
    bool m_active = true;
    bool m_complete = false;
    bool m_holding = false;
};
