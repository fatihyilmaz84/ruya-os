#include "MockThermalBackend.h"

#include <QStringList>
#include <QTimer>

#include <algorithm>

namespace {
QString labelFor(const QString &cls)
{
    if (cls == QLatin1String("cpu"))
        return QStringLiteral("Processor");
    if (cls == QLatin1String("gpu"))
        return QStringLiteral("Graphics");
    if (cls == QLatin1String("fan"))
        return QStringLiteral("Fan");
    return QStringLiteral("Drive");
}

int classOrder(const QString &cls)
{
    static const QStringList order = {QStringLiteral("cpu"), QStringLiteral("gpu"), QStringLiteral("ssd"),
                                      QStringLiteral("hdd"), QStringLiteral("fan")};
    const int i = int(order.indexOf(cls));
    return i < 0 ? int(order.size()) : i;
}
} // namespace

MockThermalBackend::MockThermalBackend(QObject *parent)
    : ThermalBackend(parent)
{
    reset();
}

void MockThermalBackend::refresh()
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

void MockThermalBackend::publish()
{
    deliver(beginRequest(), m_list);
}

void MockThermalBackend::setSensor(const QString &id, const QString &cls, double value, const QString &level)
{
    for (ThermalSensor &existing : m_list) {
        if (existing.id == id) {
            existing.cls = cls;
            existing.label = labelFor(cls);
            existing.value = value;
            existing.level = level;
            existing.maxSeen = std::max(existing.maxSeen, value);
            publish();
            return;
        }
    }
    ThermalSensor s;
    s.id = id;
    s.cls = cls;
    s.label = labelFor(cls);
    s.value = value;
    s.level = level;
    s.maxSeen = value;
    m_list.append(s);
    // The service's order: by class, then by id.
    std::stable_sort(m_list.begin(), m_list.end(), [](const ThermalSensor &a, const ThermalSensor &b) {
        const int ca = classOrder(a.cls);
        const int cb = classOrder(b.cls);
        return ca != cb ? ca < cb : a.id < b.id;
    });
    publish();
}

void MockThermalBackend::removeSensor(const QString &id)
{
    for (int i = 0; i < m_list.size(); ++i) {
        if (m_list.at(i).id == id) {
            m_list.removeAt(i);
            break;
        }
    }
    publish();
}

void MockThermalBackend::clear()
{
    m_list.clear();
    publish();
}

void MockThermalBackend::reset()
{
    m_list.clear();
    const auto add = [this](const char *id, const char *cls, double value) {
        ThermalSensor s;
        s.id = QString::fromLatin1(id);
        s.cls = QString::fromLatin1(cls);
        s.label = labelFor(s.cls);
        s.value = value;
        s.maxSeen = value;
        m_list.append(s);
    };
    add("mock:cpu", "cpu", 41);
    add("mock:ssd", "ssd", 38);
    add("mock:fan", "fan", 1820);
    publish();
}
