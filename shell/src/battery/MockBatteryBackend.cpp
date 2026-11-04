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
            publish();
            return;
        }
    }
    m_list.append(c);
    publish();
}

void MockBatteryBackend::removeController(const QString &id)
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
    ControllerBattery c;
    c.id = QStringLiteral("pad-1");
    c.name = QStringLiteral("Ruya Pad Pro");
    c.percent = 60;
    c.state = QStringLiteral("discharging");
    m_list.append(c);
    publish();
}
