#pragma once

#include "BluetoothBackend.h"

#include <QTimer>

// In-memory Bluetooth, powered on. Paired: "Ruya Pad Pro" (connected, 80 %), "Retro Pad"
// (not connected) and "Soundbar" (connected, battery unknown). Found by scans: the first scan
// lists "Flaky Pad" (pairing fails), "Sound Buds" and "Old Headset" (pairing times out); "Ruya
// Pad" needs a second scan. A scan ends by itself after a moment, like the service's.
class MockBluetoothBackend final : public BluetoothBackend
{
    Q_OBJECT

public:
    explicit MockBluetoothBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void setPowered(bool on) override;
    void startScan() override;
    void stopScan() override;
    void pair(const QString &id) override;
    void forget(const QString &id) override;
    void connectDevice(const QString &id) override;
    void disconnectDevice(const QString &id) override;

    // Tests only.
    void setBattery(const QString &id, int percent);
    void reset();

private:
    struct Entry
    {
        BtDevice dev;
        int appearAfter = 0;    // listed from this many scans on
        QString pairResult = QStringLiteral("ok");
        bool listed = false;
        bool reconnect = false; // was connected when Bluetooth went off
    };

    void initState();
    void publish();
    void answer(const QString &op, const QString &id, const QString &status);
    int indexOf(const QString &id) const;
    void endScan();

    bool m_powered = true;
    bool m_discovering = false;
    int m_scans = 0;
    QList<Entry> m_entries;
    QTimer m_scanTimer;
};
