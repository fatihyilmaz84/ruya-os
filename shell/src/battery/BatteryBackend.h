#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QObject>
#include <QString>

struct DeviceBattery
{
    QString id;
    QString name;
    QString kind = QStringLiteral("controller");    // "controller" | "headset" | "speaker" | "mouse" | "keyboard" | "other"
    int percent = 0;                                // 0-100, -1: no reading (the cluster shows no chip)
    QString state = QStringLiteral("unknown");      // "charging" | "discharging" | "full" | "unknown"
};

// Transport behind the Batteries QML singleton: org.ruyaos.Devices1.Batteries over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. Results arrive asynchronously
// through the signal.
class BatteryBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0; // reports the list

signals:
    void listed(const QList<DeviceBattery> &devices);

protected:
    // Replies can arrive out of order: number each request when it is sent and report a reply only
    // if no newer one has been reported already.
    quint64 beginRequest() { return m_listSeq.begin(); }
    void deliver(quint64 request, const QList<DeviceBattery> &devices)
    {
        if (m_listSeq.accept(request))
            emit listed(devices);
    }

private:
    RequestSequence m_listSeq;
};
