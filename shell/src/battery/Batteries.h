#pragma once

#include "BatteryBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QSet>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Devices1.Batteries: the batteries of the wireless devices (controllers,
// headsets, speakers, mice, keyboards; UPower behind it), what the status cluster shows of them,
// and the low-battery signal for controllers.
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (ruya-devices) and the mock
// elsewhere, like Network and Bluetooth.
//
// This is the one source for a controller's battery (T-161): Bluetooth.batteryLow is not raised
// for devices of kind "controller", because UPower reports a Bluetooth controller too. The other
// kinds toast through Bluetooth, so batteryLow() here is for controllers only (T-223).
class Batteries : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // Every listed device, lowest battery first (ties: discharging before charging, then by id):
    // [{ id, name, kind, family, address, percent, state, low }]. address: the Bluetooth address (the id in
    // Bluetooth.devices) of a device UPower ties to one, else ""; DeviceIcons.batteryName names the battery after
    // the paired device with it. family: a controller's ("playstation" | "xbox" |
    // "nintendo" | "8bitdo" or ""), the same word Bluetooth.devices has for the same pad. kind "controller" | "headset" | "speaker" | "mouse"
    // | "keyboard" | "other"; state "charging" | "discharging" | "full" | "unknown"; low: the device
    // is discharging at or under LowBatteryPercent.
    Q_PROPERTY(QVariantList devices READ devices NOTIFY devicesChanged)
    // What the status cluster draws: the devices that are worth a chip (not one that is 100 %
    // and on the charger), at most MaxChips of them, lowest first.
    Q_PROPERTY(QVariantList chips READ chips NOTIFY devicesChanged)
    // The worth-a-chip devices beyond MaxChips, lowest first: the cluster draws them as one "+N".
    Q_PROPERTY(QVariantList more READ more NOTIFY devicesChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    // A discharging device at or under this level is "low" (warning glyph); a controller is also
    // reported once by batteryLow().
    static constexpr int LowBatteryPercent = 15;
    // Chips in the status cluster before the rest collapse into "+N".
    static constexpr int MaxChips = 3;

    explicit Batteries(std::unique_ptr<BatteryBackend> backend, QObject *parent = nullptr);
    ~Batteries() override;

    static Batteries *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList devices() const { return m_devices; }
    QVariantList chips() const { return m_chips; }
    QVariantList more() const { return m_more; }
    bool isMock() const { return m_backend->isMock(); }

    // Tests only, and only with the mock backend (otherwise no-ops): set or add a device (kind and
    // name only matter for a new one or when given; the default kind is "controller"), remove one,
    // empty the list, the initial state (one pad at 60 %, discharging) and a household of five
    // devices (mockPopulate, for screenshots).
    Q_INVOKABLE void mockSet(const QString &id, int percent, const QString &state = QStringLiteral("discharging"),
                             const QString &kind = QString(), const QString &name = QString(),
                             const QString &family = QString(), const QString &address = QString());
    Q_INVOKABLE void mockRemove(const QString &id);
    Q_INVOKABLE void mockClear();
    Q_INVOKABLE void mockReset();
    Q_INVOKABLE void mockPopulate();
    // Asks the backend for the list; its reply arrives after `ms` and shows the list as it is now.
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;

signals:
    void devicesChanged();
    // A controller is discharging at or under LowBatteryPercent; once per crossing.
    void batteryLow(const QString &id, const QString &name, int percent, const QString &family);

private:
    void apply(const QList<DeviceBattery> &list);

    std::unique_ptr<BatteryBackend> m_backend;
    QVariantList m_devices;
    QVariantList m_chips;
    QVariantList m_more;
    QSet<QString> m_lowReported;
};
