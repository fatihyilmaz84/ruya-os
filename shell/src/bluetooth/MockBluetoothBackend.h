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
    void pair(const QString &id, bool keyboardConfirmed) override;
    void forget(const QString &id) override;
    void connectDevice(const QString &id) override;
    void disconnectDevice(const QString &id) override;
    void reportIdle(int idleSeconds, int timeoutSeconds, bool hold) override;
    void rename(const QString &id, const QString &name) override;
    void startControllerPairing(int seconds) override;
    void stopControllerPairing() override;

    // Tests only.
    // How the pairing window ends (T-203): "wait" (it stays open until stopped), "success" (a
    // controller pairs: "Ruya Pad" is paired and connected and a controller is present),
    // "timeout", "rejected" (a phone tries: the window stays open). The outcome comes a moment
    // after the start, like the service's.
    void setPairingScript(const QString &outcome) { m_pairingScript = outcome; }
    // A keyboard or gamepad is (not) connected. True at first, so every other screen is as before.
    void setInputPresent(bool present);
    int pairingStarts() const { return m_pairingStarts; }
    int idleReports() const { return m_idleReports; }
    int lastIdleSeconds() const { return m_lastIdleSeconds; }
    int lastIdleTimeout() const { return m_lastIdleTimeout; }
    bool lastIdleHold() const { return m_lastIdleHold; }
    void setBattery(const QString &id, int percent);
    // A device that was not in the list is "found" now, as if the window's scan saw it (T-260).
    void reveal(const QString &id);
    // A device's name set to any text (a device names itself; rename() would refuse some of it).
    void setName(const QString &id, const QString &name);
    void setFamily(const QString &id, const QString &family);
    // Paired without the keys kept (BlueZ's Bonded: no), or bonded.
    void setBonded(const QString &id, bool bonded);
    // A device that does not answer a scan (it is not in pairing mode): never listed by one.
    void setSilent(const QString &id, bool silent);
    // The service restarts: pads announced before are void.
    void serviceRestart() { emit gamepadsReset(); }
    // A game controller appears or goes away (USB or Bluetooth), announced a moment later like the
    // service's signal (T-260). Returns nothing; the shell reacts to gamepadConnected/Disconnected.
    // The list (ListGamepads, T-453) follows: the pads given here, plus every connected controller of
    // the device list (a Bluetooth pad is a gamepad with its address as id), without duplicates.
    void gamepadEvent(bool connected, const QString &id, const QString &name, const QString &family,
                      const QString &transport);
    // Adds one paired, connected device of every kind and every controller family the shell
    // draws, and one of a kind it does not know (icons: T-199). The ids are "bt-gallery-<what>".
    void populate();
    // Two paired, connected pads that differ only in their address (T-334): the same name, model
    // and family. Their ids are Bluetooth addresses, like the service's.
    void addTwoPads();
    void reset();
    // While held, pair() is counted but unanswered (a pairing that takes a while) until released.
    void holdPairing(bool hold);
    int pairCalls() const { return m_pairCalls; }
    QStringList pairLog() const { return m_pairLog; }
    int refreshCalls() const { return m_refreshCalls; } // refresh() calls since the start (tests)
    // Replies to refresh() arrive after `ms` (0: at once), with the state as it was when asked;
    // the number of replies still on their way. Lets a test play an old reply landing after a
    // new one.
    void setReplyDelay(int ms) { m_delay = ms; }
    int pendingReplies() const { return m_pending; }

private:
    struct Entry
    {
        BtDevice dev;
        int appearAfter = 0;    // listed from this many scans on
        QString pairResult = QStringLiteral("ok");
        bool listed = false;
        bool reconnect = false; // was connected when Bluetooth went off
        bool silent = false;    // a scan does not find it
    };

    void initState();
    void doPair(const QString &id, bool keyboardConfirmed);
    void publish(int delayMs = 0);
    QList<BtGamepad> gamepadList() const;
    void answer(const QString &op, const QString &id, const QString &status);
    int indexOf(const QString &id) const;
    void endScan();
    void finishPairing(const QString &outcome);

    bool m_powered = true;
    bool m_discovering = false;
    bool m_holdPairing = false;
    QList<QPair<QString, bool>> m_heldPairs; // id, keyboardConfirmed
    QStringList m_pairLog;
    int m_pairCalls = 0;
    int m_refreshCalls = 0;
    int m_delay = 0;
    int m_pending = 0;
    int m_scans = 0;
    QList<Entry> m_entries;
    QList<BtGamepad> m_gamepads;    // pads announced with gamepadEvent (USB ones, mostly)
    QTimer m_scanTimer;
    QTimer m_pairingTimer;
    QString m_pairing = QStringLiteral("idle");
    QString m_pairingScript = QStringLiteral("wait");
    bool m_inputPresent = true;
    int m_pairingStarts = 0;
    int m_idleReports = 0;
    int m_lastIdleSeconds = -1;
    int m_lastIdleTimeout = -1;
    bool m_lastIdleHold = false;
};
