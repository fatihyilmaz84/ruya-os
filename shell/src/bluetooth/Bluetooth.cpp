#include "Bluetooth.h"

#include "DBusBluetoothBackend.h"
#include "../battery/Batteries.h"
#include "MockBluetoothBackend.h"

#include <algorithm>

Bluetooth::Bluetooth(std::unique_ptr<BluetoothBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &BluetoothBackend::stateChanged, this, [this](bool powered, bool discovering) {
        if (powered == m_powered && discovering == m_discovering)
            return;
        m_powered = powered;
        m_discovering = discovering;
        emit stateChanged();
    });
    connect(m_backend.get(), &BluetoothBackend::controllerStateChanged, this, [this](const QString &pairing, bool present) {
        if (m_inputKnown && pairing == m_controllerPairing && present == m_inputPresent)
            return;
        m_inputKnown = true;
        m_controllerPairing = pairing;
        m_inputPresent = present;
        emit controllerStateChanged();
    });
    connect(m_backend.get(), &BluetoothBackend::controllerRejected, this, &Bluetooth::controllerRejected);
    connect(m_backend.get(), &BluetoothBackend::devicesListed, this, [this](const QList<BtDevice> &list) {
        QVariantList out;
        for (const BtDevice &d : list) {
            out.append(QVariantMap{
                {QStringLiteral("id"), d.id},
                {QStringLiteral("name"), d.name},
                {QStringLiteral("kind"), d.kind},
                {QStringLiteral("family"), d.family},
                {QStringLiteral("paired"), d.paired},
                {QStringLiteral("connected"), d.connected},
                {QStringLiteral("trusted"), d.trusted},
                {QStringLiteral("battery"), d.battery},
            });
        }
        checkBatteries(list);
        m_devices = out;
        emit devicesChanged();
    });
    connect(m_backend.get(), &BluetoothBackend::finished, this, &Bluetooth::finished);
    m_backend->refresh();
}

Bluetooth::~Bluetooth() = default;

Bluetooth *Bluetooth::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<BluetoothBackend> backend;
    // Like Audio and Network: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockBluetoothBackend>();
    else
        backend = std::make_unique<DBusBluetoothBackend>();
    return new Bluetooth(std::move(backend));
}

// A device is "low" while it is connected with a known battery at or under the limit
// (Batteries::LowBatteryPercent, the same one the status cluster and the controller toast use). It is reported
// when it enters that state and again only after it left it (recharged, or disconnected).
void Bluetooth::checkBatteries(const QList<BtDevice> &devices)
{
    for (const BtDevice &d : devices) {
        // Controllers are covered by Batteries (UPower), which reports the same battery.
        const bool low = d.kind != QLatin1String("controller") && d.connected && d.battery >= 0
                         && d.battery <= Batteries::LowBatteryPercent;
        if (!low) {
            m_lowReported.remove(d.id);
        } else if (!m_lowReported.contains(d.id)) {
            m_lowReported.insert(d.id);
            emit batteryLow(d.id, d.name, d.battery, d.kind, d.family);
        }
    }
    const QSet<QString> reported = m_lowReported;   // forget devices that left the list
    for (const QString &id : reported) {
        const bool listed = std::any_of(devices.begin(), devices.end(), [&id](const BtDevice &d) { return d.id == id; });
        if (!listed)
            m_lowReported.remove(id);
    }
}

void Bluetooth::setPowered(bool on)
{
    m_backend->setPowered(on);
}

void Bluetooth::startScan()
{
    m_backend->startScan();
}

void Bluetooth::stopScan()
{
    m_backend->stopScan();
}

void Bluetooth::pair(const QString &id)
{
    m_backend->pair(id);
}

void Bluetooth::forget(const QString &id)
{
    m_backend->forget(id);
}

void Bluetooth::connectDevice(const QString &id)
{
    m_backend->connectDevice(id);
}

void Bluetooth::disconnectDevice(const QString &id)
{
    m_backend->disconnectDevice(id);
}

void Bluetooth::startControllerPairing()
{
    m_backend->startControllerPairing(ControllerPairingSeconds);
}

void Bluetooth::stopControllerPairing()
{
    m_backend->stopControllerPairing();
}

void Bluetooth::mockPairingScript(const QString &outcome)
{
    if (auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get()))
        mock->setPairingScript(outcome);
}

void Bluetooth::mockSetInputPresent(bool present)
{
    if (auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get()))
        mock->setInputPresent(present);
}

int Bluetooth::mockPairingStarts() const
{
    auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get());
    return mock ? mock->pairingStarts() : 0;
}

void Bluetooth::mockSetBattery(const QString &id, int percent)
{
    if (auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get()))
        mock->setBattery(id, percent);
}

void Bluetooth::mockPopulate()
{
    if (auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get()))
        mock->populate();
}

void Bluetooth::mockHoldPairing(bool hold)
{
    if (auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get()))
        mock->holdPairing(hold);
}

int Bluetooth::mockPairCalls() const
{
    if (auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get()))
        return mock->pairCalls();
    return 0;
}

void Bluetooth::mockReset()
{
    if (auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get()))
        mock->reset();
}

void Bluetooth::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get())) {
        mock->setReplyDelay(ms);
        mock->refresh();
        mock->setReplyDelay(0);
    }
}

int Bluetooth::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
