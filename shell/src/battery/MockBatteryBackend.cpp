#include "MockBatteryBackend.h"

#include <QTimer>

MockBatteryBackend::MockBatteryBackend(QObject *parent)
    : BatteryBackend(parent)
{
    reset();
}

void MockBatteryBackend::refresh()
{
    const quint64 request = beginRequest();
    if (m_delay <= 0) {
        deliver(request, m_list);
        return;
    }
    ++m_pending;
    QTimer::singleShot(m_delay, this, [this, request, snapshot = m_list] {
        --m_pending;
        deliver(request, snapshot);
    });
}

void MockBatteryBackend::publish()
{
    deliver(beginRequest(), m_list);
}

void MockBatteryBackend::setDevice(const QString &id, int percent, const QString &state, const QString &kind,
                                   const QString &name, const QString &family, const QString &address,
                                   const QString &model)
{
    for (DeviceBattery &existing : m_list) {
        if (existing.id != id)
            continue;
        existing.percent = percent < 0 ? -1 : qMin(percent, 100);
        existing.state = state;
        if (!kind.isEmpty())
            existing.kind = kind;
        if (!name.isEmpty())
            existing.name = name;
        if (!family.isEmpty())
            existing.family = family;
        if (!address.isEmpty())
            existing.address = address;
        if (!model.isEmpty())
            existing.model = model;
        publish();
        return;
    }
    DeviceBattery c;
    c.id = id;
    c.kind = kind.isEmpty() ? QStringLiteral("controller") : kind;
    c.name = name.isEmpty() ? QStringLiteral("Ruya %1 (%2)").arg(c.kind, id) : name;
    c.percent = percent < 0 ? -1 : qMin(percent, 100);
    c.state = state;
    c.family = family;
    c.address = address;
    c.model = model;
    m_list.append(c);
    publish();
}

void MockBatteryBackend::removeDevice(const QString &id)
{
    for (int i = 0; i < m_list.size(); ++i) {
        if (m_list.at(i).id == id) {
            m_list.removeAt(i);
            break;
        }
    }
    publish();
}

void MockBatteryBackend::clear()
{
    m_list.clear();
    publish();
}

void MockBatteryBackend::reset()
{
    m_list.clear();
    DeviceBattery c;
    c.id = QStringLiteral("pad-1");
    c.name = QStringLiteral("Ruya Pad Pro");
    c.percent = 60;
    c.state = QStringLiteral("discharging");
    c.address = QStringLiteral("bt-pad-main");   // the Bluetooth mock's connected pad: one pad, one row (T-453)
    m_list.append(c);
    publish();
}

void MockBatteryBackend::populate()
{
    m_list.clear();
    const auto add = [this](const char *id, const char *name, const char *kind, int percent, const char *state,
                            const char *family = "", const char *model = "") {
        DeviceBattery d;
        d.id = QString::fromLatin1(id);
        d.name = QString::fromLatin1(name);
        d.kind = QString::fromLatin1(kind);
        d.percent = percent;
        d.state = QString::fromLatin1(state);
        d.family = QString::fromLatin1(family);
        d.model = QString::fromLatin1(model);
        m_list.append(d);
    };
    add("pad-1", "DualSense Wireless Controller", "controller", 62, "charging", "playstation", "dualsense");
    add("pad-2", "Xbox Wireless Controller", "controller", 41, "discharging", "xbox", "xbox_series");
    add("headset-1", "WH-1000XM4", "headset", 78, "discharging");
    add("keyboard-1", "Ruya Keyboard", "keyboard", 94, "discharging");
    add("mouse-1", "Ruya Mouse", "mouse", 12, "discharging");
    publish();
}
