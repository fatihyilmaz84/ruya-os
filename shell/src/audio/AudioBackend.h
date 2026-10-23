#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

struct SinkInfo
{
    QString id;
    QString name;
    QString kind; // "hdmi" | "analog" | "usb" | "bluetooth"
    bool isDefault = false;
};

// Transport behind the Audio QML singleton: org.ruyaos.Devices1.Audio over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. Results arrive asynchronously
// through signals. stateChanged is emitted after every command, even when the state did not
// change (the volume OSD still shows when the user presses Volume Up at 100).
class AudioBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    // The channels of the contract, in order.
    static QStringList channelNames() { return {QStringLiteral("ui"), QStringLiteral("ambient"), QStringLiteral("media")}; }

    virtual bool isMock() const = 0;
    virtual void refresh() = 0;                      // reports the state and the outputs
    virtual void setVolume(int volume) = 0;          // 0-100, clamped by the backend
    virtual void setMuted(bool muted) = 0;
    virtual void setChannelVolume(const QString &channel, int value) = 0; // 0-100, clamped
    virtual void setDefaultSink(const QString &id) = 0;

signals:
    // channels: channel name -> 0-100, all channels of channelNames().
    void stateChanged(int volume, bool muted, const QVariantMap &channels);
    void sinksListed(const QList<SinkInfo> &sinks);
    // status: see the XML ("ok", "unknown-sink", "failed").
    void setDefaultSinkFinished(const QString &id, const QString &status);
};
