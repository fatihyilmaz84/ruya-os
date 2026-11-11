#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QObject>
#include <QString>

struct BtDevice
{
    QString id;
    QString name;       // the alias: what the user calls it, else what it calls itself
    QString deviceName; // what it calls itself (BlueZ's Name, the model); "" when it told none (T-300)
    // "controller" | "headset" | "speaker" | "keyboard" | "mouse" | "phone" | "other"
    QString kind = QStringLiteral("other");
    // "playstation" | "xbox" | "nintendo" | "8bitdo" for a controller the service can place, else ""
    QString family;
    bool paired = false;
    bool bonded = true; // the pairing keys are kept; false: paired but only reconnects in pairing mode (T-300)
    bool connected = false;
    bool trusted = false;
    int battery = -1; // 0-100, -1 unknown
    // The adapter that holds the device ("hci0"), for a log or a bug report; no screen shows it (T-336).
    QString adapter;
};

// A game controller present now (Devices1.Bluetooth.ListGamepads, T-453).
struct BtGamepad
{
    QString id;        // stable per pad: the Bluetooth address when it has one, else the USB port, else the name
    QString name;
    QString family;    // "playstation" | "xbox" | "nintendo" | "8bitdo" | ""
    QString transport; // "usb" | "bluetooth" | "other"
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
    // Gives a device a name of the user's (BlueZ Alias, T-260): finished("rename", id, status).
    virtual void rename(const QString &id, const QString &name) = 0;
    // The controller pairing window (T-203): the status of the start arrives as
    // finished("controller-pairing", "start", status) (and "stop" for the stop); the state follows by controllerStateChanged.
    virtual void startControllerPairing(int seconds) = 0;
    virtual void stopControllerPairing() = 0;
    // How long the console has been without input, for the idle-controller rule of the service
    // (Devices1.Bluetooth.ReportIdle, T-202). No reply is reported; timeoutSeconds 0 is "never".
    virtual void reportIdle(int idleSeconds, int timeoutSeconds, bool hold) = 0;

signals:
    void stateChanged(bool powered, bool discovering);
    // pairing: "idle" | "open" | "paired" | "timeout" (ControllerPairingState); inputPresent: a
    // keyboard or gamepad is connected (InputPresent). Reported together with stateChanged.
    void controllerStateChanged(const QString &pairing, bool inputPresent);
    // The window refused a device that is not an input device.
    void controllerRejected();
    // A game controller appeared or went away, over USB or Bluetooth (T-260). id is stable per pad;
    // family: "playstation" | "xbox" | "nintendo" | "8bitdo" | ""; transport: "usb" | "bluetooth" | "other".
    void gamepadConnected(const QString &id, const QString &name, const QString &family, const QString &transport);
    void gamepadDisconnected(const QString &id, const QString &name, const QString &family, const QString &transport);
    // The service went away (or came back): what was said about pads before is void, the next read of
    // the service is a new baseline.
    void gamepadsReset();
    void devicesListed(const QList<BtDevice> &devices);
    // The controllers present now (ListGamepads): after every refresh and after every
    // gamepadConnected / gamepadDisconnected.
    void gamepadsListed(const QList<BtGamepad> &pads);
    // op: "power" | "scan" | "pair" | "forget" | "connect" | "disconnect" | "rename" | "controller-pairing";
    // id: "" for power and scan, "start" or "stop" for controller-pairing; status: see the XML ("ok", "pairing-failed", "timeout", ...).
    void finished(const QString &op, const QString &id, const QString &status);

protected:
    // Replies can arrive out of order: number each request when it is sent and report a reply only
    // if no newer one of the same kind has been reported already (the state and the device list
    // are two kinds). RequestSequence.h.
    quint64 beginStateRequest() { return m_stateSeq.begin(); }
    void deliverState(quint64 request, bool powered, bool discovering, const QString &pairing, bool inputPresent)
    {
        if (!m_stateSeq.accept(request))
            return;
        emit stateChanged(powered, discovering);
        emit controllerStateChanged(pairing, inputPresent);
    }
    quint64 beginDevicesRequest() { return m_devicesSeq.begin(); }
    void deliverDevices(quint64 request, const QList<BtDevice> &devices)
    {
        if (m_devicesSeq.accept(request))
            emit devicesListed(devices);
    }

    quint64 beginGamepadsRequest() { return m_gamepadsSeq.begin(); }
    void deliverGamepads(quint64 request, const QList<BtGamepad> &pads)
    {
        if (m_gamepadsSeq.accept(request))
            emit gamepadsListed(pads);
    }

private:
    RequestSequence m_stateSeq;
    RequestSequence m_devicesSeq;
    RequestSequence m_gamepadsSeq;
};
