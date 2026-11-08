#pragma once

#include <QElapsedTimer>
#include <QObject>
#include <QQmlEngine>

// The idle clock's time source (T-293): milliseconds from a monotonic clock, so a change of the
// wall clock (NTP, a time zone, a user setting the date) moves nothing, plus the time the machine
// has spent suspended. On Linux the monotonic clock stops while the machine sleeps; that is why
// `sleptMs` exists: it is CLOCK_BOOTTIME minus CLOCK_MONOTONIC and grows only across a suspend,
// so IdleClock can tell "the console slept" from "the clock was changed". Elsewhere it stays 0.
class MonotonicClock : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit MonotonicClock(QObject *parent = nullptr);

    static MonotonicClock *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    // Milliseconds since the shell started, on the monotonic clock.
    Q_INVOKABLE double ms() const;
    // Total milliseconds this machine has been suspended since boot (0 where it cannot be told).
    Q_INVOKABLE double sleptMs() const;

    // Tests only: move both readings forward as if time had passed / the machine had slept.
    Q_INVOKABLE void mockAdvance(double ms) { m_offsetMs += ms; }
    Q_INVOKABLE void mockSleep(double ms) { m_sleptOffsetMs += ms; }

private:
    QElapsedTimer m_timer;
    double m_offsetMs = 0;
    double m_sleptOffsetMs = 0;
};
