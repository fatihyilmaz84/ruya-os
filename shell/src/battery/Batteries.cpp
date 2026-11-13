#include "Batteries.h"

#include "DBusBatteryBackend.h"
#include "MockBatteryBackend.h"

#include <algorithm>

Batteries::Batteries(std::unique_ptr<BatteryBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &BatteryBackend::listed, this, &Batteries::apply);
    m_backend->refresh();
}

Batteries::~Batteries() = default;

Batteries *Batteries::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<BatteryBackend> backend;
    // Like Network and Bluetooth: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockBatteryBackend>();
    else
        backend = std::make_unique<DBusBatteryBackend>();
    return new Batteries(std::move(backend));
}

void Batteries::apply(const QList<DeviceBattery> &input)
{
    // Lowest first; on a tie the discharging one (it is the one that will run out), then by id.
    QList<DeviceBattery> list;
    for (const DeviceBattery &c : input) {
        if (c.percent >= 0) // a device without a reading has no chip
            list.append(c);
    }
    const auto discharging = [](const DeviceBattery &c) { return c.state == QLatin1String("discharging"); };
    std::stable_sort(list.begin(), list.end(), [&](const DeviceBattery &a, const DeviceBattery &b) {
        if (a.percent != b.percent)
            return a.percent < b.percent;
        if (discharging(a) != discharging(b))
            return discharging(a);
        return a.id < b.id;
    });
    QVariantList devices;
    QVariantList shown;
    for (const DeviceBattery &c : list) {
        const bool low = discharging(c) && c.percent <= LowBatteryPercent;
        const QVariantMap entry{
            {QStringLiteral("id"), c.id},
            {QStringLiteral("name"), c.name},
            {QStringLiteral("kind"), c.kind},
            {QStringLiteral("percent"), c.percent},
            {QStringLiteral("state"), c.state},
            {QStringLiteral("family"), c.family},
            {QStringLiteral("model"), c.model},
            {QStringLiteral("address"), c.address},
            {QStringLiteral("low"), low},
        };
        devices.append(entry);
        // A full battery on the charger is not news: no chip (it comes back when it is unplugged).
        const bool onCharger = c.state == QLatin1String("charging") || c.state == QLatin1String("full");
        if (!(onCharger && c.percent >= 100))
            shown.append(entry);
    }
    const QVariantList chips = shown.mid(0, MaxChips);
    const QVariantList more = shown.mid(MaxChips);
    // The low-battery rule first, so a listener of devicesChanged sees the toast's reason. Only
    // controllers: the other kinds are Bluetooth.batteryLow's.
    for (const DeviceBattery &c : list) {
        const bool low = c.kind == QLatin1String("controller") && discharging(c) && c.percent <= LowBatteryPercent;
        if (!low) {
            m_lowReported.remove(c.id);
        } else if (!m_lowReported.contains(c.id)) {
            m_lowReported.insert(c.id);
            emit batteryLow(c.id, c.name, c.percent, c.family, c.model);
        }
    }
    const QSet<QString> reported = m_lowReported; // forget controllers that left the list
    for (const QString &id : reported) {
        const bool listed = std::any_of(list.begin(), list.end(), [&id](const DeviceBattery &c) { return c.id == id; });
        if (!listed)
            m_lowReported.remove(id);
    }
    if (devices == m_devices)
        return;
    m_devices = devices;
    m_chips = chips;
    m_more = more;
    emit devicesChanged();
}

void Batteries::mockSet(const QString &id, int percent, const QString &state, const QString &kind, const QString &name,
                        const QString &family, const QString &address, const QString &model)
{
    if (auto *mock = qobject_cast<MockBatteryBackend *>(m_backend.get()))
        mock->setDevice(id, percent, state, kind, name, family, address, model);
}

void Batteries::mockRemove(const QString &id)
{
    if (auto *mock = qobject_cast<MockBatteryBackend *>(m_backend.get()))
        mock->removeDevice(id);
}

void Batteries::mockClear()
{
    if (auto *mock = qobject_cast<MockBatteryBackend *>(m_backend.get()))
        mock->clear();
}

void Batteries::mockReset()
{
    if (auto *mock = qobject_cast<MockBatteryBackend *>(m_backend.get()))
        mock->reset();
}

void Batteries::mockPopulate()
{
    if (auto *mock = qobject_cast<MockBatteryBackend *>(m_backend.get()))
        mock->populate();
}

void Batteries::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockBatteryBackend *>(m_backend.get())) {
        mock->setReplyDelay(ms);
        mock->refresh();
        mock->setReplyDelay(0);
    }
}

int Batteries::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockBatteryBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
