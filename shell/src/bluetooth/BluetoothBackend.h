#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QObject>
#include <QString>

struct BtDevice
{
    QString id;
    QString name;
    QString kind = QStringLiteral("other"); // "controller" | "headset" | "audio" | "other"
    bool paired = false;
    bool connected = false;
    bool trusted = false;
    int battery = -1; // 0-100, -1 unknown
};

// Transport behind the Bluetooth QML singleton: org.ruyaos.Devices1.Bluetooth over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. Results arrive asynchronously
// through signals.
class BluetoothBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0; // reports the state and the devices
    virtual void setPowered(bool on) = 0;
    virtual void startScan() = 0;
    virtual void stopScan() = 0;
    virtual void pair(const QString &id) = 0;
    virtual void forget(const QString &id) = 0;
    virtual void connectDevice(const QString &id) = 0;
    virtual void disconnectDevice(const QString &id) = 0;

signals:
    void stateChanged(bool powered, bool discovering);
    void devicesListed(const QList<BtDevice> &devices);
    // op: "power" | "scan" | "pair" | "forget" | "connect" | "disconnect"; id: "" for power and
    // scan; status: see the XML ("ok", "pairing-failed", "timeout", ...).
    void finished(const QString &op, const QString &id, const QString &status);

protected:
    // Replies can arrive out of order: number each request when it is sent and report a reply only
    // if no newer one of the same kind has been reported already (the state and the device list
    // are two kinds). RequestSequence.h.
    quint64 beginStateRequest() { return m_stateSeq.begin(); }
    void deliverState(quint64 request, bool powered, bool discovering)
    {
        if (m_stateSeq.accept(request))
            emit stateChanged(powered, discovering);
    }
    quint64 beginDevicesRequest() { return m_devicesSeq.begin(); }
    void deliverDevices(quint64 request, const QList<BtDevice> &devices)
    {
        if (m_devicesSeq.accept(request))
            emit devicesListed(devices);
    }

private:
    RequestSequence m_stateSeq;
    RequestSequence m_devicesSeq;
};
