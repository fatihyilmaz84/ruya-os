#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QObject>
#include <QString>

struct ThermalSensor
{
    QString id;
    QString label;                                  // English role; the shell translates by class
    QString cls;                                    // "cpu" | "gpu" | "ssd" | "hdd" | "fan"
    double value = 0;                               // degrees Celsius; rpm for a fan
    QString level = QStringLiteral("normal");       // "normal" | "warm" | "hot" | "critical"
    double maxSeen = 0;
};

// Transport behind the Thermal QML singleton: org.ruyaos.Devices1.Thermal over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. Results arrive asynchronously
// through the signal.
class ThermalBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0; // reports the list

signals:
    void listed(const QList<ThermalSensor> &sensors);

protected:
    // Replies can arrive out of order: number each request when it is sent and report a reply only
    // if no newer one has been reported already.
    quint64 beginRequest() { return m_listSeq.begin(); }
    // A request that failed is an outcome too: call this for it, so an older reply landing after
    // the failure is dropped (T-191).
    void acceptFailure(quint64 request) { m_listSeq.accept(request); }
    void deliver(quint64 request, const QList<ThermalSensor> &sensors)
    {
        if (m_listSeq.accept(request))
            emit listed(sensors);
    }

private:
    RequestSequence m_listSeq;
};
