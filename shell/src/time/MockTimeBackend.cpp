#include "MockTimeBackend.h"

#include <QTimer>

namespace {
// A sample of IANA names: every region the list groups by, a three-part name, and "UTC".
const char *const Zones[] = {
    "Africa/Abidjan", "Africa/Cairo", "Africa/Johannesburg", "Africa/Lagos", "Africa/Nairobi",
    "America/Anchorage", "America/Argentina/Buenos_Aires", "America/Bogota", "America/Chicago",
    "America/Denver", "America/Halifax", "America/Los_Angeles", "America/Mexico_City",
    "America/New_York", "America/Sao_Paulo", "America/Toronto", "America/Vancouver",
    "Antarctica/McMurdo", "Arctic/Longyearbyen",
    "Asia/Baghdad", "Asia/Bangkok", "Asia/Dhaka", "Asia/Dubai", "Asia/Hong_Kong",
    "Asia/Jakarta", "Asia/Karachi", "Asia/Kathmandu", "Asia/Kolkata", "Asia/Manila",
    "Asia/Seoul", "Asia/Shanghai", "Asia/Singapore", "Asia/Tehran", "Asia/Tokyo",
    "Atlantic/Azores", "Atlantic/Reykjavik",
    "Australia/Adelaide", "Australia/Brisbane", "Australia/Perth", "Australia/Sydney",
    "Europe/Amsterdam", "Europe/Athens", "Europe/Berlin", "Europe/Brussels", "Europe/Dublin",
    "Europe/Helsinki", "Europe/Istanbul", "Europe/Lisbon", "Europe/London", "Europe/Madrid",
    "Europe/Moscow", "Europe/Paris", "Europe/Rome", "Europe/Stockholm", "Europe/Warsaw",
    "Europe/Zurich",
    "Indian/Maldives", "Indian/Mauritius",
    "Pacific/Auckland", "Pacific/Fiji", "Pacific/Honolulu", "Pacific/Port_Moresby",
    "UTC",
};
} // namespace

MockTimeBackend::MockTimeBackend(QObject *parent)
    : TimeBackend(parent)
{
    for (const char *z : Zones)
        m_zones.append(QString::fromLatin1(z));
    reset();
}

void MockTimeBackend::reset()
{
    m_timezone = QStringLiteral("UTC");
    m_ntp = true;
    m_callerAllowed = true;
    m_failNext = false;
    m_setCalls = 0;
    if (m_zonesWithheld)
        releaseZones();
    publish();
}

void MockTimeBackend::publish()
{
    deliverState(beginStateRequest(), m_timezone, m_ntp);
}

void MockTimeBackend::refresh()
{
    publish();
}

void MockTimeBackend::refreshDelayed(int ms)
{
    const quint64 request = beginStateRequest();
    ++m_pending;
    QTimer::singleShot(ms, this, [this, request, zone = m_timezone, ntp = m_ntp] {
        --m_pending;
        deliverState(request, zone, ntp);
    });
}

void MockTimeBackend::loadZones()
{
    QTimer::singleShot(0, this, [this] { emit zonesListed(m_zonesWithheld ? QStringList() : m_zones); });
}

void MockTimeBackend::withholdZones()
{
    m_zonesWithheld = true;
    loadZones();        // the facade drops the list it has
}

void MockTimeBackend::releaseZones()
{
    m_zonesWithheld = false;
    loadZones();
}

void MockTimeBackend::setTimezone(const QString &name)
{
    ++m_setCalls;
    QTimer::singleShot(0, this, [this, name] {
        QString status = QStringLiteral("ok");
        if (!m_callerAllowed) {
            status = QStringLiteral("forbidden");
        } else if (!m_zones.contains(name)) {
            status = QStringLiteral("invalid");
        } else if (m_failNext) {
            m_failNext = false;
            status = QStringLiteral("failed");
        } else if (name != m_timezone) {
            m_timezone = name;
            publish();
        }
        emit setTimezoneFinished(name, status);
    });
}

void MockTimeBackend::setOutside(const QString &name)
{
    m_timezone = name;
    publish();
}

void MockTimeBackend::setNtp(bool synchronised)
{
    m_ntp = synchronised;
    publish();
}
