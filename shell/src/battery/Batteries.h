#pragma once

#include "BatteryBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QSet>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Devices1.Batteries: the batteries of the gaming controllers (UPower
// behind it), the lowest level for the status cluster, and the low-battery signal.
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (ruya-devices) and the mock
// elsewhere, like Network and Bluetooth.
//
// This is the one source for a controller's battery (T-161): Bluetooth.batteryLow is not raised
// for devices of kind "controller", because UPower reports a Bluetooth controller too.
class Batteries : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // [{ id, name, percent, state }], state "charging" | "discharging" | "full" | "unknown"
    Q_PROPERTY(QVariantList controllers READ controllers NOTIFY controllersChanged)
    // The level the cluster shows, -1 when there is no controller: the lowest percent, but when the
    // lowest is charging (or tied with a discharging one) the lowest discharging controller.
    Q_PROPERTY(int lowest READ lowest NOTIFY controllersChanged)
    // The state of the controller `lowest` belongs to ("" when there is none).
    Q_PROPERTY(QString lowestState READ lowestState NOTIFY controllersChanged)
    // The lowest controller is discharging at or under LowBatteryPercent.
    Q_PROPERTY(bool low READ isLow NOTIFY controllersChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    // A discharging controller at or under this level is reported once by batteryLow().
    static constexpr int LowBatteryPercent = 15;

    explicit Batteries(std::unique_ptr<BatteryBackend> backend, QObject *parent = nullptr);
    ~Batteries() override;

    static Batteries *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList controllers() const { return m_controllers; }
    int lowest() const { return m_lowest; }
    QString lowestState() const { return m_lowestState; }
    bool isLow() const { return m_lowest >= 0 && m_lowestState == QLatin1String("discharging") && m_lowest <= LowBatteryPercent; }
    bool isMock() const { return m_backend->isMock(); }

    // Tests only, and only with the mock backend (otherwise no-ops): set or add a controller,
    // remove one, empty the list, and the initial state (one pad at 60 %, discharging).
    Q_INVOKABLE void mockSet(const QString &id, int percent, const QString &state = QStringLiteral("discharging"));
    Q_INVOKABLE void mockRemove(const QString &id);
    Q_INVOKABLE void mockClear();
    Q_INVOKABLE void mockReset();
    // Asks the backend for the list; its reply arrives after `ms` and shows the list as it is now.
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;

signals:
    void controllersChanged();
    // A controller is discharging at or under LowBatteryPercent; once per crossing.
    void batteryLow(const QString &id, const QString &name, int percent);

private:
    void apply(const QList<ControllerBattery> &list);

    std::unique_ptr<BatteryBackend> m_backend;
    QVariantList m_controllers;
    int m_lowest = -1;
    QString m_lowestState;
    QSet<QString> m_lowReported;
};
