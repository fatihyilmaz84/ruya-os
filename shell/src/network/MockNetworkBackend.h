#pragma once

#include "NetworkBackend.h"

// In-memory network: wired and connected; Wi-Fi "Lounge 5G" (WPA, saved), "HomeNet" (WPA,
// not saved), "Cafe Guest" (open) and "Campus" (enterprise). Every WPA network accepts the
// password MockNetworkBackend::password().
class MockNetworkBackend final : public NetworkBackend
{
    Q_OBJECT

public:
    explicit MockNetworkBackend(QObject *parent = nullptr);

    static QString password() { return QStringLiteral("ruya-wifi-pass"); }

    bool isMock() const override { return true; }
    void refresh() override;
    int refreshCalls() const { return m_refreshCalls; } // refresh() calls since the start (tests)
    void scan() override;
    void connectWifi(const QString &id, const QString &password) override;
    void forget(const QString &id) override;
    void setWifiEnabled(bool on) override;

    // Tests only.
    void setCable(bool plugged);
    // What the radio switch answers: "ok" (default) or "failed" (a refused switch: the state stays).
    void setWifiScript(const QString &status) { m_wifiStatus = status; }
    // Whether the service offers a radio switch at all ("unsupported" when not).
    void setWifiSupported(bool supported);
    void reset();
    // A network's name as an access point could broadcast it (any text); publishes the lists.
    void setSsid(const QString &id, const QString &ssid);
    // Replies to refresh() arrive after `ms` (0: at once), with the state as it was when asked;
    // the number of replies still on their way. Lets a test play an old reply landing after a
    // new one.
    void setReplyDelay(int ms) { m_delay = ms; }
    int pendingReplies() const { return m_pending; }

private:
    void initState();
    void publishState(int delayMs = 0);
    void publishNetworks(int delayMs = 0);
    int indexOf(const QString &id) const;

    bool m_cable = true;
    bool m_wifiOn = true;
    bool m_wifiSupported = true;
    QString m_wifiStatus = QStringLiteral("ok");
    QList<WifiInfo> m_networks;
    int m_delay = 0;
    int m_pending = 0;
    int m_refreshCalls = 0;
};
