#pragma once

#include <QList>
#include <QObject>
#include <QString>

struct ControllerBattery
{
    QString id;
    QString name;
    int percent = 0;                                // 0-100
    QString state = QStringLiteral("unknown");      // "charging" | "discharging" | "full" | "unknown"
};

// Transport behind the Batteries QML singleton: org.ruyaos.Devices1.Batteries over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. Results arrive asynchronously
// through the signal.
class BatteryBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0; // reports the list

signals:
    void listed(const QList<ControllerBattery> &controllers);

protected:
    // Replies can arrive out of order: number each request when it is sent and report a reply only
    // if no newer one has been reported already.
    quint64 beginRequest() { return ++m_issued; }
    void deliver(quint64 request, const QList<ControllerBattery> &controllers)
    {
        if (request <= m_applied)
            return;
        m_applied = request;
        emit listed(controllers);
    }

private:
    quint64 m_issued = 0;
    quint64 m_applied = 0;
};
