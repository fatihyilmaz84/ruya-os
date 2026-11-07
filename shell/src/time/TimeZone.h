#pragma once

#include "TimeBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QStringList>
#include <QTimeZone>
#include <QTimer>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Devices1.Time: the console's time zone (T-213), the list of zones to
// choose from and the clock text the status cluster shows. Named TimeZone (not Time) because a
// header called Time.h shadows <time.h> on a case-insensitive file system.
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (ruya-devices) and the mock
// elsewhere, like Network and Batteries.
//
// The clock is computed here from the zone name (QTimeZone), not from the process's local time:
// Qt reads the system zone once, and the shell must show a zone change at once.
class TimeZone : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The zone as an IANA name; "UTC" until the service has answered.
    Q_PROPERTY(QString timezone READ timezone NOTIFY timezoneChanged)
    // The system clock is set from the network. False on a console that has not been online yet.
    Q_PROPERTY(bool ntpSynchronised READ ntpSynchronised NOTIFY ntpSynchronisedChanged)
    // Every name the system knows, sorted; empty until the service has answered.
    Q_PROPERTY(QStringList timezones READ timezones NOTIFY timezonesChanged)
    // The part before the first "/" of each name, sorted, with "Other" (names without one: "UTC")
    // last. The words are IANA's; the pickers translate them.
    Q_PROPERTY(QStringList regions READ regions NOTIFY timezonesChanged)
    // "HH:mm" now, in the zone; refreshed every ten seconds and at once on a zone change.
    Q_PROPERTY(QString clockText READ clockText NOTIFY clockTextChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit TimeZone(std::unique_ptr<TimeBackend> backend, QObject *parent = nullptr);
    ~TimeZone() override;

    static TimeZone *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QString timezone() const { return m_timezone; }
    bool ntpSynchronised() const { return m_ntp; }
    QStringList timezones() const { return m_zones; }
    QStringList regions() const { return m_regions; }
    QString clockText() const { return m_clockText; }
    bool isMock() const { return m_backend->isMock(); }

    // The cities of a region, sorted by name: [{ zone: "Europe/Istanbul", city: "Istanbul" }];
    // city is readable ("Buenos_Aires" -> "Buenos Aires", "Argentina/Buenos_Aires" -> "Argentina / Buenos Aires").
    Q_INVOKABLE QVariantList citiesIn(const QString &region) const;
    // The region of a zone name ("Europe" for "Europe/Istanbul", "Other" for "UTC").
    Q_INVOKABLE QString regionOf(const QString &zone) const;
    // A sensible zone to offer for a language: "tr" -> Europe/Istanbul, otherwise Europe/London;
    // "" when the list does not have it (or is not loaded yet).
    Q_INVOKABLE QString defaultZoneFor(const QString &language) const;
    // The clock text for an instant (milliseconds since the epoch) in the current zone.
    Q_INVOKABLE QString formatClock(qint64 msSinceEpoch) const;
    // Asks the service to set the zone; the answer comes as setTimezoneFinished.
    Q_INVOKABLE void setTimezone(const QString &name);

    // Tests only, and only with the mock backend (otherwise no-ops).
    Q_INVOKABLE void mockReset();
    Q_INVOKABLE void mockSetOutside(const QString &name);   // timedatectl changed the zone
    Q_INVOKABLE void mockSetNtp(bool synchronised);
    Q_INVOKABLE void mockSetCallerAllowed(bool allowed);    // false: SetTimezone answers "forbidden"
    Q_INVOKABLE void mockFailNext();                        // the next SetTimezone answers "failed"
    Q_INVOKABLE int mockSetCalls() const;
    Q_INVOKABLE void mockWithholdZones();                   // ListTimezones has not answered yet: the list is empty
    Q_INVOKABLE void mockReleaseZones();                    // ... and now it answers
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;

signals:
    void timezoneChanged();
    void ntpSynchronisedChanged();
    void timezonesChanged();
    void clockTextChanged();
    // status: "ok" | "invalid" | "forbidden" | "failed"
    void setTimezoneFinished(const QString &name, const QString &status);

private:
    void applyState(const QString &timezone, bool ntp);
    void applyZones(const QStringList &names);
    void updateClock();

    std::unique_ptr<TimeBackend> m_backend;
    QString m_timezone = QStringLiteral("UTC");
    bool m_ntp = false;
    QStringList m_zones;
    QStringList m_regions;
    QTimeZone m_zone;
    QString m_clockText;
    QTimer m_tick;
};
