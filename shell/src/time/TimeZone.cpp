#include "TimeZone.h"

#include "DBusTimeBackend.h"
#include "MockTimeBackend.h"

#include <QDateTime>
#include <QVariantMap>

#include <algorithm>

namespace {
const QString OtherRegion = QStringLiteral("Other");

// "Europe/Istanbul" -> "Europe"; a name without a slash -> "Other".
QString regionPart(const QString &zone)
{
    const int slash = zone.indexOf(QLatin1Char('/'));
    return slash > 0 ? zone.left(slash) : OtherRegion;
}

// "Argentina/Buenos_Aires" -> "Argentina / Buenos Aires"; "UTC" -> "UTC".
QString cityPart(const QString &zone)
{
    const int slash = zone.indexOf(QLatin1Char('/'));
    QString city = slash > 0 ? zone.mid(slash + 1) : zone;
    city.replace(QLatin1Char('_'), QLatin1Char(' '));
    city.replace(QLatin1Char('/'), QStringLiteral(" / "));
    return city;
}
} // namespace

TimeZone::TimeZone(std::unique_ptr<TimeBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    m_zone = QTimeZone(m_timezone.toUtf8());
    connect(m_backend.get(), &TimeBackend::stateChanged, this, &TimeZone::applyState);
    connect(m_backend.get(), &TimeBackend::zonesListed, this, &TimeZone::applyZones);
    connect(m_backend.get(), &TimeBackend::setTimezoneFinished, this,
            [this](const QString &name, const QString &status) {
                // The backend has already reported the new zone (through its request sequence).
                emit setTimezoneFinished(name, status);
            });
    m_tick.setInterval(10000);
    connect(&m_tick, &QTimer::timeout, this, &TimeZone::updateClock);
    m_tick.start();
    updateClock();
    m_backend->refresh();
    m_backend->loadZones();
}

TimeZone::~TimeZone() = default;

TimeZone *TimeZone::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<TimeBackend> backend;
    // Like Network and Batteries: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockTimeBackend>();
    else
        backend = std::make_unique<DBusTimeBackend>();
    return new TimeZone(std::move(backend));
}

void TimeZone::applyState(const QString &timezone, bool ntp)
{
    if (ntp != m_ntp) {
        m_ntp = ntp;
        emit ntpSynchronisedChanged();
    }
    if (timezone.isEmpty() || timezone == m_timezone) {
        // The list may still be missing (the service started after the shell).
        if (m_zones.isEmpty())
            m_backend->loadZones();
        return;
    }
    m_timezone = timezone;
    m_zone = QTimeZone(timezone.toUtf8());
    if (!m_zone.isValid())
        qWarning("ruya-shell: the time zone %s is not known to Qt; the clock shows local time", qPrintable(timezone));
    emit timezoneChanged();
    updateClock();
    if (m_zones.isEmpty())
        m_backend->loadZones();
}

void TimeZone::applyZones(const QStringList &names)
{
    QStringList sorted = names;
    sorted.removeDuplicates();
    std::sort(sorted.begin(), sorted.end());
    if (sorted == m_zones)
        return;
    m_zones = sorted;
    QStringList regions;
    for (const QString &z : m_zones) {
        const QString r = regionPart(z);
        if (!regions.contains(r))
            regions.append(r);
    }
    // Alphabetical, with the names that have no region last.
    std::sort(regions.begin(), regions.end(), [](const QString &a, const QString &b) {
        if ((a == OtherRegion) != (b == OtherRegion))
            return b == OtherRegion;
        return a < b;
    });
    m_regions = regions;
    emit timezonesChanged();
}

QString TimeZone::formatClock(qint64 msSinceEpoch) const
{
    const QDateTime utc = QDateTime::fromMSecsSinceEpoch(msSinceEpoch, QTimeZone::UTC);
    const QDateTime shown = m_zone.isValid() ? utc.toTimeZone(m_zone) : utc.toLocalTime();
    return shown.toString(QStringLiteral("HH:mm"));
}

QString TimeZone::formatIsoDate(qint64 msSinceEpoch) const
{
    const QDateTime utc = QDateTime::fromMSecsSinceEpoch(msSinceEpoch, QTimeZone::UTC);
    const QDateTime shown = m_zone.isValid() ? utc.toTimeZone(m_zone) : utc.toLocalTime();
    return shown.toString(QStringLiteral("yyyy-MM-dd"));
}

void TimeZone::updateClock()
{
    const QString text = formatClock(QDateTime::currentMSecsSinceEpoch());
    if (text == m_clockText)
        return;
    m_clockText = text;
    emit clockTextChanged();
}

QVariantList TimeZone::citiesIn(const QString &region) const
{
    QVariantList out;
    for (const QString &z : m_zones) {
        if (regionPart(z) != region)
            continue;
        out.append(QVariantMap{{QStringLiteral("zone"), z}, {QStringLiteral("city"), cityPart(z)}});
    }
    return out;
}

QString TimeZone::regionOf(const QString &zone) const
{
    return regionPart(zone);
}

QString TimeZone::defaultZoneFor(const QString &language) const
{
    const QString zone = language == QLatin1String("tr") ? QStringLiteral("Europe/Istanbul")
                                                         : QStringLiteral("Europe/London");
    return m_zones.contains(zone) ? zone : QString();
}

void TimeZone::setTimezone(const QString &name)
{
    m_backend->setTimezone(name);
}

void TimeZone::mockReset()
{
    if (auto *mock = qobject_cast<MockTimeBackend *>(m_backend.get()))
        mock->reset();
}

void TimeZone::mockSetOutside(const QString &name)
{
    if (auto *mock = qobject_cast<MockTimeBackend *>(m_backend.get()))
        mock->setOutside(name);
}

void TimeZone::mockSetNtp(bool synchronised)
{
    if (auto *mock = qobject_cast<MockTimeBackend *>(m_backend.get()))
        mock->setNtp(synchronised);
}

void TimeZone::mockSetCallerAllowed(bool allowed)
{
    if (auto *mock = qobject_cast<MockTimeBackend *>(m_backend.get()))
        mock->setCallerAllowed(allowed);
}

void TimeZone::mockFailNext()
{
    if (auto *mock = qobject_cast<MockTimeBackend *>(m_backend.get()))
        mock->setFailNext(true);
}

void TimeZone::mockWithholdZones()
{
    if (auto *mock = qobject_cast<MockTimeBackend *>(m_backend.get()))
        mock->withholdZones();
}

void TimeZone::mockReleaseZones()
{
    if (auto *mock = qobject_cast<MockTimeBackend *>(m_backend.get()))
        mock->releaseZones();
}

int TimeZone::mockSetCalls() const
{
    auto *mock = qobject_cast<MockTimeBackend *>(m_backend.get());
    return mock ? mock->setCalls() : 0;
}

void TimeZone::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockTimeBackend *>(m_backend.get()))
        mock->refreshDelayed(ms);
}

int TimeZone::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockTimeBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
