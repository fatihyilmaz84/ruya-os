#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

struct WifiInfo
{
    QString id;
    QString ssid;
    int signal = 0;                            // 0-100
    QString security = QStringLiteral("open"); // "open" | "wpa-psk" | "enterprise"
    bool known = false;
    bool active = false;
};

// Transport behind the Network QML singleton: org.ruyaos.Devices1.Network over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. Results arrive asynchronously
// through signals.
class NetworkBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0; // reports the state and the networks
    virtual void scan() = 0;
    virtual void connectWifi(const QString &id, const QString &password) = 0;
    virtual void forget(const QString &id) = 0;

signals:
    // state: "disconnected" | "connecting" | "connected" | "limited"; primary: see the XML
    // (empty when disconnected).
    void stateChanged(const QString &state, const QVariantMap &primary);
    void networksListed(const QList<WifiInfo> &networks);
    // status: see the XML ("ok", "wrong-password", "unsupported", ...).
    void connectFinished(const QString &id, const QString &status);
    void forgetFinished(const QString &id, const QString &status);

protected:
    // Replies can arrive out of order: number each request when it is sent and report a reply only
    // if no newer one of the same kind has been reported already (the state and the network list
    // are two kinds). RequestSequence.h.
    quint64 beginStateRequest() { return m_stateSeq.begin(); }
    void deliverState(quint64 request, const QString &state, const QVariantMap &primary)
    {
        if (m_stateSeq.accept(request))
            emit stateChanged(state, primary);
    }
    quint64 beginNetworksRequest() { return m_networksSeq.begin(); }
    void deliverNetworks(quint64 request, const QList<WifiInfo> &networks)
    {
        if (m_networksSeq.accept(request))
            emit networksListed(networks);
    }

private:
    RequestSequence m_stateSeq;
    RequestSequence m_networksSeq;
};
