#pragma once

#include "BluetoothBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QSet>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Devices1.Bluetooth: adapter power, scanning and the device list.
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (ruya-devices, T-132) and
// the mock elsewhere, like Audio, Network and Profiles.
class Bluetooth : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool powered READ powered NOTIFY stateChanged)
    Q_PROPERTY(bool discovering READ discovering NOTIFY stateChanged)
    // [{ id, name, kind, paired, connected, trusted, battery }]; battery -1 = unknown
    Q_PROPERTY(QVariantList devices READ devices NOTIFY devicesChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    // A connected device (not a controller: Batteries reports those) under this battery level is
    // reported once by batteryLow().
    static constexpr int LowBatteryPercent = 15;

    explicit Bluetooth(std::unique_ptr<BluetoothBackend> backend, QObject *parent = nullptr);
    ~Bluetooth() override;

    static Bluetooth *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    bool powered() const { return m_powered; }
    bool discovering() const { return m_discovering; }
    QVariantList devices() const { return m_devices; }
    bool isMock() const { return m_backend->isMock(); }

    Q_INVOKABLE void setPowered(bool on);
    Q_INVOKABLE void startScan();
    Q_INVOKABLE void stopScan();
    Q_INVOKABLE void pair(const QString &id);
    Q_INVOKABLE void forget(const QString &id);
    Q_INVOKABLE void connectDevice(const QString &id);
    Q_INVOKABLE void disconnectDevice(const QString &id);

    // Tests only, and only with the mock backend (otherwise no-ops): a device's battery, and
    // the initial state.
    Q_INVOKABLE void mockSetBattery(const QString &id, int percent);
    Q_INVOKABLE void mockReset();
    // Asks the backend for the state and the devices; the replies arrive after `ms` and show them
    // as they are now. mockPendingReplies: how many are still on their way.
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;
    // Hold pair() unanswered until released (false); mockPairCalls() counts the pair() calls
    // since the last reset.
    Q_INVOKABLE void mockHoldPairing(bool hold);
    Q_INVOKABLE int mockPairCalls() const;

signals:
    void stateChanged();
    void devicesChanged();
    // op: "power" | "scan" | "pair" | "forget" | "connect" | "disconnect"; status: see
    // api/dbus/org.ruyaos.Devices1.xml
    void finished(const QString &op, const QString &id, const QString &status);
    // A connected device's battery fell under LowBatteryPercent; once per crossing.
    void batteryLow(const QString &id, const QString &name, int percent);

private:
    void checkBatteries(const QList<BtDevice> &devices);

    std::unique_ptr<BluetoothBackend> m_backend;
    bool m_powered = false;
    bool m_discovering = false;
    QVariantList m_devices;
    QSet<QString> m_lowReported;
};
