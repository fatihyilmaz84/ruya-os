#include "Bluetooth.h"

#include "DBusBluetoothBackend.h"
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
    connect(m_backend.get(), &BluetoothBackend::devicesListed, this, [this](const QList<BtDevice> &list) {
        QVariantList out;
        for (const BtDevice &d : list) {
            out.append(QVariantMap{
                {QStringLiteral("id"), d.id},
                {QStringLiteral("name"), d.name},
                {QStringLiteral("kind"), d.kind},
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

// A device is "low" while it is connected with a known battery under the limit. It is reported
// when it enters that state and again only after it left it (recharged, or disconnected).
void Bluetooth::checkBatteries(const QList<BtDevice> &devices)
{
    for (const BtDevice &d : devices) {
        // Controllers are covered by Batteries (UPower), which reports the same battery.
        const bool low = d.kind != QLatin1String("controller") && d.connected && d.battery >= 0
                         && d.battery < LowBatteryPercent;
        if (!low) {
            m_lowReported.remove(d.id);
        } else if (!m_lowReported.contains(d.id)) {
            m_lowReported.insert(d.id);
            emit batteryLow(d.id, d.name, d.battery);
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

void Bluetooth::mockSetBattery(const QString &id, int percent)
{
    if (auto *mock = qobject_cast<MockBluetoothBackend *>(m_backend.get()))
        mock->setBattery(id, percent);
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
