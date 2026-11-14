#pragma once

#include "RequestSequence.h"

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

// Transport behind the Input QML singleton (RUY-409): org.ruyaos.Input1 of ruya-inputd over D-Bus,
// or an in-memory mock: the routing (SetRoute, 06 §5.1-5.2, RUY-409), the devices, their
// capabilities and the button test (RUY-39 / T-368), the controller profiles (RUY-42 / T-369);
// UI ownership and ownership modes follow with their tasks (T-371, T-397).
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
    // Input1.ListDevices; the answer arrives as devicesListed (the newest request only).
    virtual void refreshDevices() = 0;
    // Input1.GetCapabilities(device_id); the answer arrives as capabilitiesFinished.
    virtual void getCapabilities(const QString &deviceId) = 0;
    // Input1.StartTest / StopTest; StartTest's answer arrives as testStartFinished.
    virtual void startTest(const QString &deviceId, bool holdLeftStick) = 0;
    virtual void stopTest(const QString &deviceId) = 0;
    // A controller profile member (InputProfileCalls.h; RUY-42) with its in-arguments by the XML's
    // names. The answer arrives as profileReply with the same token and the out-arguments by name
    // (status "failed", the others empty, when the call itself failed).
    virtual void callProfile(quint64 token, const QString &method, const QVariantMap &args) = 0;
    // Reads the ConfirmButton property (06 section 11.2: the signed-in profile's mode); the answer
    // arrives as confirmButtonRead.
    virtual void readConfirmButton() = 0;

signals:
    // The newest SetRoute's answer: a status string of api/dbus/org.ruyaos.Input1.xml, or "failed"
    // when the call itself failed (no service, a D-Bus error). Older answers are dropped.
    void routeFinished(const QString &status);
    // org.ruyaos.Input1 has a (new) owner: a restarted service starts in the route "shell", so the
    // shell sends its route again.
    void serviceAppeared();
    // The name gained or lost its owner.
    void serviceOwnedChanged(bool owned);
    // ListDevices answered (ok) or failed: the device records as maps with the contract's keys
    // (id, instance, name, family, connection, battery, charging, slot, profile, routed).
    void devicesListed(bool ok, const QVariantList &devices);
    // DeviceAdded, DeviceChanged or DeviceRemoved: the list is out of date.
    void devicesChanged();
    // GetCapabilities: maps { name, hardware, driver, available, output }, in descriptor order;
    // status "failed" when the call itself failed.
    void capabilitiesFinished(const QString &deviceId, const QString &status, const QVariantList &capabilities);
    void testStartFinished(const QString &deviceId, const QString &status);
    void testInput(const QString &deviceId, const QString &input, int value, const QString &source);
    void testEnded(const QString &deviceId, const QString &reason);
    void profileReply(quint64 token, const QString &method, const QVariantMap &args, const QVariantMap &reply);
    // The ConfirmButton property answered: mode "family" | "south" | "east", ok false when the call
    // failed (no service).
    void confirmButtonRead(bool ok, const QString &mode);
    // The property changed (a profile switch or SetConfirmButton): read it again.
    void confirmButtonChanged();
    // ActiveInputChanged(device_id, family): the last press came from that device.
    void activeInputChanged(const QString &deviceId, const QString &family);
    // UserActive: a pad is being played in the app in front (RUY-588; at most every 30 s, no content).
    void userActive();
    // ProfilesChanged: the controller profiles of that console profile changed.
    void profilesChanged(const QString &profile);

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
    quint64 beginDevicesRequest() { return m_devicesSeq.begin(); }
    void deliverDevices(quint64 request, bool ok, const QVariantList &devices)
    {
        if (m_devicesSeq.accept(request))
            emit devicesListed(ok, devices);
    }

private:
    RequestSequence m_seq;
    RequestSequence m_devicesSeq;
    bool m_serviceOwned = true;
};
