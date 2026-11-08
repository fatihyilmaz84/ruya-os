#include "MonotonicClock.h"

#ifdef Q_OS_LINUX
#include <time.h>
#endif

MonotonicClock::MonotonicClock(QObject *parent)
    : QObject(parent)
{
    m_timer.start();
}

MonotonicClock *MonotonicClock::create(QQmlEngine *, QJSEngine *)
{
    return new MonotonicClock;
}

double MonotonicClock::ms() const
{
    return double(m_timer.elapsed()) + m_offsetMs;
}

double MonotonicClock::sleptMs() const
{
    double slept = 0;
#ifdef Q_OS_LINUX
    timespec mono {};
    timespec boot {};
    if (clock_gettime(CLOCK_MONOTONIC, &mono) == 0 && clock_gettime(CLOCK_BOOTTIME, &boot) == 0) {
        const double diff = (double(boot.tv_sec) - double(mono.tv_sec)) * 1000.0
                          + (double(boot.tv_nsec) - double(mono.tv_nsec)) / 1.0e6;
        slept = diff > 0 ? diff : 0;
    }
#endif
    return slept + m_sleptOffsetMs;
}
