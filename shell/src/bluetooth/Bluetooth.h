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
    // [{ id, name, deviceName, kind, family, paired, bonded, connected, trusted, battery, adapter }]; battery -1 = unknown;
    // adapter: the adapter that holds it ("hci0"; "" from an older service), shown nowhere;
    // name: the alias; deviceName: the model it advertises ("" when unknown); bonded: false for a device
    // paired without its keys kept (a missing key from an older service reads as true);
    // kind: "controller" | "headset" | "speaker" | "keyboard" | "mouse" | "phone" | "other";
    // family: "playstation" | "xbox" | "nintendo" | "8bitdo" for a controller, else ""
    Q_PROPERTY(QVariantList devices READ devices NOTIFY devicesChanged)
    // The controller pairing window (T-203): "idle" | "open" | "paired" | "timeout".
    Q_PROPERTY(QString controllerPairing READ controllerPairing NOTIFY controllerStateChanged)
    // A keyboard or gamepad is connected. True until the service says otherwise, so a screen
    // does not flash a "no controller" hint at start-up; inputKnown says the service answered.
    Q_PROPERTY(bool inputPresent READ inputPresent NOTIFY controllerStateChanged)
    Q_PROPERTY(bool inputKnown READ inputKnown NOTIFY controllerStateChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    // A connected device (not a controller: Batteries reports those) at or under
    // Batteries::LowBatteryPercent is reported once by batteryLow().
    // How long the window the shell opens stays open (the service's default).
    static constexpr int ControllerPairingSeconds = 120;

    explicit Bluetooth(std::unique_ptr<BluetoothBackend> backend, QObject *parent = nullptr);
    ~Bluetooth() override;

    static Bluetooth *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    bool powered() const { return m_powered; }
    bool discovering() const { return m_discovering; }
    QVariantList devices() const { return m_devices; }
    bool isMock() const { return m_backend->isMock(); }
    QString controllerPairing() const { return m_controllerPairing; }
    bool inputPresent() const { return m_inputPresent; }
    bool inputKnown() const { return m_inputKnown; }

    Q_INVOKABLE void setPowered(bool on);
    Q_INVOKABLE void startScan();
    Q_INVOKABLE void stopScan();
    Q_INVOKABLE void pair(const QString &id);
    Q_INVOKABLE void forget(const QString &id);
    Q_INVOKABLE void connectDevice(const QString &id);
    Q_INVOKABLE void disconnectDevice(const QString &id);
    // Gives a device a name of the user's (BlueZ Alias); finished("rename", id, status).
    Q_INVOKABLE void rename(const QString &id, const QString &name);
    // Opens the window in which a controller (or keyboard) can pair itself, and closes it. The
    // status of the start arrives as finished("controller-pairing", "start", status); the stop answers with id "stop".
    Q_INVOKABLE void startControllerPairing();
    Q_INVOKABLE void stopControllerPairing();
    // Tells the service how long the console has been quiet, so that it can switch idle pads off
    // (T-202; the rule is the service's, see Devices1.xml). timeoutSeconds 0: never. hold: an app
    // or an install keeps the pads on.
    Q_INVOKABLE void reportIdle(int idleSeconds, int timeoutSeconds, bool hold);

    // Tests only, and only with the mock backend (otherwise no-ops): a device's battery, and
    // the initial state.
    Q_INVOKABLE void mockSetBattery(const QString &id, int percent);
    Q_INVOKABLE void mockReset();
    // Adds a paired, connected device of every kind and controller family, and of one kind that
    // is not known (T-199); mockReset() takes them away again.
    Q_INVOKABLE void mockPopulate();
    // Adds two paired, connected DualSense pads with the same name, "Wireless Controller", the
    // addresses AA:00:00:00:00:04 and :05 (T-334; batteries 80 and 55 %); mockReset() removes them.
    Q_INVOKABLE void mockTwoPads();
    // Asks the backend for the state and the devices; the replies arrive after `ms` and show them
    // as they are now. mockPendingReplies: how many are still on their way.
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;
    // Hold pair() unanswered until released (false); mockPairCalls() counts the pair() calls
    // since the last reset.
    Q_INVOKABLE void mockHoldPairing(bool hold);
    Q_INVOKABLE int mockPairCalls() const;
    // How many times the backend was asked for the state and the devices (T-349).
    Q_INVOKABLE int mockRefreshCalls() const;
    // How the window ends ("wait", "success", "timeout", "rejected"); whether an input device is
    // present; how many times the window was started.
    Q_INVOKABLE void mockPairingScript(const QString &outcome);
    Q_INVOKABLE void mockSetInputPresent(bool present);
    // A device that was hidden is found now; a game controller appears or goes away (T-260).
    Q_INVOKABLE void mockReveal(const QString &id);
    Q_INVOKABLE void mockSetName(const QString &id, const QString &name);   // any text, as a device could send it
    Q_INVOKABLE void mockSetFamily(const QString &id, const QString &family);
    Q_INVOKABLE void mockSetBonded(const QString &id, bool bonded);
    // A device a scan does not find (it is not in pairing mode), or finds again.
    Q_INVOKABLE void mockSetSilent(const QString &id, bool silent);
    Q_INVOKABLE void mockServiceRestart();
    Q_INVOKABLE void mockGamepad(bool connected, const QString &id, const QString &name, const QString &family,
                                 const QString &transport);
    Q_INVOKABLE int mockPairingStarts() const;
    // The idle reports the mock got since the last reset, and the last one (0 / -1 before any).
    Q_INVOKABLE int mockIdleReports() const;
    Q_INVOKABLE int mockLastIdleSeconds() const;
    Q_INVOKABLE int mockLastIdleTimeout() const;
    Q_INVOKABLE bool mockLastIdleHold() const;

signals:
    void stateChanged();
    void devicesChanged();
    void controllerStateChanged();
    // A device that is not a controller tried to pair while the window was open.
    void controllerRejected();
    // A game controller appeared or went away (USB or Bluetooth, T-260). family: "playstation" | "xbox" |
    // "nintendo" | "8bitdo" | ""; transport: "usb" | "bluetooth" | "other"; id is stable per pad.
    void gamepadConnected(const QString &id, const QString &name, const QString &family, const QString &transport);
    void gamepadDisconnected(const QString &id, const QString &name, const QString &family, const QString &transport);
    // The service restarted: pads announced before are forgotten.
    void gamepadsReset();
    // op: "power" | "scan" | "pair" | "forget" | "connect" | "disconnect" | "rename" | "controller-pairing"; status: see
    // api/dbus/org.ruyaos.Devices1.xml
    void finished(const QString &op, const QString &id, const QString &status);
    // A connected device's battery fell to Batteries::LowBatteryPercent or less; once per crossing.
    void batteryLow(const QString &id, const QString &name, int percent, const QString &kind, const QString &family);

private:
    void checkBatteries(const QList<BtDevice> &devices);

    std::unique_ptr<BluetoothBackend> m_backend;
    bool m_powered = false;
    bool m_discovering = false;
    QString m_controllerPairing = QStringLiteral("idle");
    bool m_inputPresent = true;
    bool m_inputKnown = false;
    QVariantList m_devices;
    QSet<QString> m_lowReported;
};
