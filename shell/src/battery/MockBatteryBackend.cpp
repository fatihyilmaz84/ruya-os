#include "MockBatteryBackend.h"

MockBatteryBackend::MockBatteryBackend(QObject *parent)
    : BatteryBackend(parent)
{
    reset();
}

void MockBatteryBackend::refresh()
{
    emit listed(m_list);
}

void MockBatteryBackend::setController(const QString &id, int percent, const QString &state)
{
    ControllerBattery c;
    c.id = id;
    c.name = QStringLiteral("Ruya Pad (%1)").arg(id);
    c.percent = qBound(0, percent, 100);
    c.state = state;
    for (ControllerBattery &existing : m_list) {
        if (existing.id == id) {
            c.name = existing.name;
            existing = c;
            emit listed(m_list);
            return;
        }
    }
    m_list.append(c);
    emit listed(m_list);
}

void MockBatteryBackend::removeController(const QString &id)
{
    for (int i = 0; i < m_list.size(); ++i) {
        if (m_list.at(i).id == id) {
            m_list.removeAt(i);
            break;
        }
    }
    emit listed(m_list);
}

void MockBatteryBackend::clear()
{
    m_list.clear();
    emit listed(m_list);
}

void MockBatteryBackend::reset()
{
    m_list.clear();
    ControllerBattery c;
    c.id = QStringLiteral("pad-1");
    c.name = QStringLiteral("Ruya Pad Pro");
    c.percent = 60;
    c.state = QStringLiteral("discharging");
    m_list.append(c);
    emit listed(m_list);
}
