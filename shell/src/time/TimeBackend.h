#pragma once

#include "RequestSequence.h"

#include <QObject>
#include <QString>
#include <QStringList>

// Transport behind the Time QML singleton: org.ruyaos.Devices1.Time over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. Results arrive asynchronously through
// signals.
class TimeBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0;                          // reports the zone and the NTP state
    virtual void loadZones() = 0;                        // reports the list of zone names
    virtual void setTimezone(const QString &name) = 0;   // reports the status

signals:
    void stateChanged(const QString &timezone, bool ntpSynchronised);
    void zonesListed(const QStringList &names);
    // status: "ok" | "invalid" | "forbidden" | "failed" (see the XML header)
    void setTimezoneFinished(const QString &name, const QString &status);

protected:
    // Replies can arrive out of order (TimezoneChanged crosses a GetTimezone reply): number each
    // state request when it is sent and report a reply only if no newer one was reported already.
    quint64 beginStateRequest() { return m_stateSeq.begin(); }
    bool acceptState(quint64 request) { return m_stateSeq.accept(request); }
    void deliverState(quint64 request, const QString &timezone, bool ntpSynchronised)
    {
        if (acceptState(request))
            emit stateChanged(timezone, ntpSynchronised);
    }

private:
    RequestSequence m_stateSeq;
};
