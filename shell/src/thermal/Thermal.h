#pragma once

#include "ThermalBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Devices1.Thermal: the console's temperatures and fans and the worst
// level they add up to. The service measures and classifies; what the console does about a warm,
// hot or critical level is the shell's (qml/ThermalPolicy.qml). Backend: RUYA_SERVICES=mock|dbus;
// the default is D-Bus on Linux (ruya-devices) and the mock elsewhere, like Batteries.
class Thermal : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // [{ id, label, cls, value, level, maxSeen }] in the service's order (processor, graphics,
    // drives, fans); cls "cpu" | "gpu" | "ssd" | "hdd" | "fan"; value in degrees Celsius, rpm for a
    // fan; level "normal" | "warm" | "hot" | "critical".
    Q_PROPERTY(QVariantList sensors READ sensors NOTIFY sensorsChanged)
    // The worst level of the sensors.
    Q_PROPERTY(QString level READ level NOTIFY levelChanged)
    // The id of the first sensor that holds `level` ("" while it is normal). levelChanged is sent
    // after the list and both values are updated.
    Q_PROPERTY(QString levelSensor READ levelSensor NOTIFY levelChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Thermal(std::unique_ptr<ThermalBackend> backend, QObject *parent = nullptr);
    ~Thermal() override;

    static Thermal *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList sensors() const { return m_sensors; }
    QString level() const { return m_level; }
    QString levelSensor() const { return m_levelSensor; }
    bool isMock() const { return m_backend->isMock(); }

    // The sensor with this id, or an empty object.
    Q_INVOKABLE QVariantMap sensor(const QString &id) const;

    // Tests only, and only with the mock backend (otherwise no-ops): set or add a sensor with
    // the level the service would report, remove one, empty the list, and the initial state.
    Q_INVOKABLE void mockSet(const QString &id, const QString &cls, double value, const QString &level);
    Q_INVOKABLE void mockRemove(const QString &id);
    Q_INVOKABLE void mockClear();
    Q_INVOKABLE void mockReset();
    // Asks the backend for the list; its reply arrives after `ms` and shows the list as it is now.
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;

signals:
    void sensorsChanged();
    void levelChanged();

private:
    void apply(const QList<ThermalSensor> &list);

    std::unique_ptr<ThermalBackend> m_backend;
    QVariantList m_sensors;
    QString m_level = QStringLiteral("normal");
    QString m_levelSensor;
};
