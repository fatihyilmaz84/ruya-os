#pragma once

#include "RequestSequence.h"

#include <QObject>
#include <QString>

// Transport behind the Input QML singleton (RUY-409): org.ruyaos.Input1 of ruya-inputd over D-Bus,
// or an in-memory mock. Only the routing members are used today (SetRoute, 06 §5.1-5.2); the
// devices, profiles and the button test follow with their tasks (T-368..T-371, T-397).
class InputBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    // Whether org.ruyaos.Input1 has an owner now (RUY-410): the emergency pad reader starts when it
    // has had none for 3 s (06 section 8). True until the first answer, so a slow bus start-up
    // does not read as a dead service.
    bool serviceOwned() const { return m_serviceOwned; }
    // Input1.SetRoute(route, instance, app_id, profile); the answer arrives as routeFinished.
    virtual void setRoute(const QString &route, const QString &instance, const QString &appId,
                          const QString &profile) = 0;

signals:
    // The newest SetRoute's answer: a status string of api/dbus/org.ruyaos.Input1.xml, or "failed"
    // when the call itself failed (no service, a D-Bus error). Older answers are dropped.
    void routeFinished(const QString &status);
    // org.ruyaos.Input1 has a (new) owner: a restarted service starts in the route "shell", so the
    // shell sends its route again.
    void serviceAppeared();
    // The name gained or lost its owner.
    void serviceOwnedChanged(bool owned);

protected:
    void setServiceOwned(bool owned)
    {
        if (owned == m_serviceOwned)
            return;
        m_serviceOwned = owned;
        emit serviceOwnedChanged(owned);
    }

    // Replies can arrive out of order: number each SetRoute when it is sent, report only the newest
    // outcome so far (RequestSequence.h, T-181; a failure counts, T-191).
    quint64 beginRoute() { return m_seq.begin(); }
    void deliverRoute(quint64 request, const QString &status)
    {
        if (m_seq.accept(request))
            emit routeFinished(status);
    }

private:
    RequestSequence m_seq;
    bool m_serviceOwned = true;
};
