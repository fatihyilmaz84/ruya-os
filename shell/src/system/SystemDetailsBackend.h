#pragma once

#include "RequestSequence.h"

#include <QObject>
#include <QVariantMap>

// Transport behind the SystemDetails QML singleton: org.ruyaos.Devices1.System over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. The reply is the service's dictionary of
// grouped keys (`cpu.model`, `memory.total_bytes`, ...), with nested lists as QVariantList of
// QVariantMap (`storage.drives`); a value that could not be read is absent. Results arrive
// asynchronously through the signal.
class SystemDetailsBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0; // reports the dictionary

signals:
    void listed(const QVariantMap &info);

protected:
    // Replies can arrive out of order: number each request when it is sent and report a reply only
    // if no newer one has been reported already (RequestSequence.h). A failed request is an outcome
    // too: acceptFailure() it, so an older reply landing after it is dropped (T-191).
    quint64 beginRequest() { return m_seq.begin(); }
    void acceptFailure(quint64 request) { m_seq.accept(request); }
    void deliver(quint64 request, const QVariantMap &info)
    {
        if (m_seq.accept(request))
            emit listed(info);
    }

private:
    RequestSequence m_seq;
};
