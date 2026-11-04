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

void Batteries::apply(const QList<ControllerBattery> &list)
{
    QVariantList out;
    for (const ControllerBattery &c : list) {
        out.append(QVariantMap{
            {QStringLiteral("id"), c.id},
            {QStringLiteral("name"), c.name},
            {QStringLiteral("percent"), c.percent},
            {QStringLiteral("state"), c.state},
        });
    }
    // The cluster shows the lowest pad; on a tie, or when that pad is charging, the discharging one
    // (lowest of those), so the warning colour agrees with the low-battery toast.
    const auto discharging = [](const ControllerBattery &c) { return c.state == QLatin1String("discharging"); };
    const ControllerBattery *shown = nullptr;
    for (const ControllerBattery &c : list) {
        if (!shown || c.percent < shown->percent)
            shown = &c;
    }
    if (shown && !discharging(*shown)) {
        for (const ControllerBattery &c : list) {
            if (discharging(c) && (!discharging(*shown) || c.percent < shown->percent))
                shown = &c;
        }
    }
    const int lowest = shown ? shown->percent : -1;
    const QString lowestState = shown ? shown->state : QString();
    // The low-battery rule first, so a listener of controllersChanged sees the toast's reason.
    for (const ControllerBattery &c : list) {
        const bool low = c.state == QLatin1String("discharging") && c.percent <= LowBatteryPercent;
        if (!low) {
            m_lowReported.remove(c.id);
        } else if (!m_lowReported.contains(c.id)) {
            m_lowReported.insert(c.id);
            emit batteryLow(c.id, c.name, c.percent);
        }
    }
    const QSet<QString> reported = m_lowReported; // forget controllers that left the list
    for (const QString &id : reported) {
        const bool listed = std::any_of(list.begin(), list.end(), [&id](const ControllerBattery &c) { return c.id == id; });
        if (!listed)
            m_lowReported.remove(id);
    }
    if (out == m_controllers)
        return;
    m_controllers = out;
    m_lowest = lowest;
    m_lowestState = lowestState;
    emit controllersChanged();
}

void Batteries::mockSet(const QString &id, int percent, const QString &state)
{
    if (auto *mock = qobject_cast<MockBatteryBackend *>(m_backend.get()))
        mock->setController(id, percent, state);
}

void Batteries::mockRemove(const QString &id)
{
    if (auto *mock = qobject_cast<MockBatteryBackend *>(m_backend.get()))
        mock->removeController(id);
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
