#pragma once

#include "AudioBackend.h"

#include <QDBusConnection>

// Client of org.ruyaos.Devices1.Audio (api/dbus/org.ruyaos.Devices1.xml) on the system bus,
// or the session bus when RUYA_DBUS=session. Unverified: the service (ruya-devices, blocker
// B-007) does not exist yet.
class DBusAudioBackend final : public AudioBackend
{
    Q_OBJECT

public:
    explicit DBusAudioBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void setVolume(int volume) override;
    void setMuted(bool muted) override;
    void setChannelVolume(const QString &channel, int value) override;
    void setDefaultSink(const QString &id) override;

private slots:
    void onSinksChanged();
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);

private:
    void refreshState();
    void refreshSinks();
    void setProperty(const QString &name, const QVariant &value);

    QDBusConnection m_bus;
};
