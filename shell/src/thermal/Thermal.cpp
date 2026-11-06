#include "Thermal.h"

#include "DBusThermalBackend.h"
#include "MockThermalBackend.h"

namespace {
int rank(const QString &level)
{
    if (level == QLatin1String("critical"))
        return 3;
    if (level == QLatin1String("hot"))
        return 2;
    if (level == QLatin1String("warm"))
        return 1;
    return 0;
}
} // namespace

Thermal::Thermal(std::unique_ptr<ThermalBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &ThermalBackend::listed, this, &Thermal::apply);
    m_backend->refresh();
}

Thermal::~Thermal() = default;

Thermal *Thermal::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<ThermalBackend> backend;
    // Like Batteries: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockThermalBackend>();
    else
        backend = std::make_unique<DBusThermalBackend>();
    return new Thermal(std::move(backend));
}

void Thermal::apply(const QList<ThermalSensor> &list)
{
    QVariantList out;
    QString level = QStringLiteral("normal");
    QString levelSensor;
    for (const ThermalSensor &s : list) {
        out.append(QVariantMap{
            {QStringLiteral("id"), s.id},
            {QStringLiteral("label"), s.label},
            {QStringLiteral("cls"), s.cls},
            {QStringLiteral("value"), s.value},
            {QStringLiteral("level"), s.level},
            {QStringLiteral("maxSeen"), s.maxSeen},
        });
        if (rank(s.level) > rank(level)) {
            level = s.level;
            levelSensor = s.id;
        }
    }
    const bool listChanged = out != m_sensors;
    const bool levelDiffers = level != m_level || levelSensor != m_levelSensor;
    m_sensors = out;
    m_level = level;
    m_levelSensor = levelSensor;
    // The list first, so a listener of levelChanged finds the sensor it is told about.
    if (listChanged)
        emit sensorsChanged();
    if (levelDiffers)
        emit levelChanged();
}

QVariantMap Thermal::sensor(const QString &id) const
{
    for (const QVariant &v : m_sensors) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("id")).toString() == id)
            return m;
    }
    return {};
}

void Thermal::mockSet(const QString &id, const QString &cls, double value, const QString &level)
{
    if (auto *mock = qobject_cast<MockThermalBackend *>(m_backend.get()))
        mock->setSensor(id, cls, value, level);
}

void Thermal::mockRemove(const QString &id)
{
    if (auto *mock = qobject_cast<MockThermalBackend *>(m_backend.get()))
        mock->removeSensor(id);
}

void Thermal::mockClear()
{
    if (auto *mock = qobject_cast<MockThermalBackend *>(m_backend.get()))
        mock->clear();
}

void Thermal::mockReset()
{
    if (auto *mock = qobject_cast<MockThermalBackend *>(m_backend.get()))
        mock->reset();
}

void Thermal::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockThermalBackend *>(m_backend.get())) {
        mock->setReplyDelay(ms);
        mock->refresh();
        mock->setReplyDelay(0);
    }
}

int Thermal::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockThermalBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
