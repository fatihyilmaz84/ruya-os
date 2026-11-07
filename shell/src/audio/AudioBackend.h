#pragma once

#include "RequestSequence.h"

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
    // Something plays through an output (Devices1.Audio Playing, T-202). Sent with every accepted
    // state report that carries it.
    void playingReported(bool playing);
    void sinksListed(const QList<SinkInfo> &sinks);
    // status: see the XML ("ok", "unknown-sink", "failed").
    void setDefaultSinkFinished(const QString &id, const QString &status);

protected:
    // Replies can arrive out of order: number each request when it is sent and report a reply only
    // if no newer one of the same kind has been reported already (the state and the output list
    // are two kinds). RequestSequence.h.
    quint64 beginStateRequest() { return m_stateSeq.begin(); }
    bool deliverState(quint64 request, int volume, bool muted, const QVariantMap &channels)
    {
        if (!m_stateSeq.accept(request))
            return false;
        emit stateChanged(volume, muted, channels);
        return true;
    }
    quint64 beginSinksRequest() { return m_sinksSeq.begin(); }
    void deliverSinks(quint64 request, const QList<SinkInfo> &sinks)
    {
        if (m_sinksSeq.accept(request))
            emit sinksListed(sinks);
    }

private:
    RequestSequence m_stateSeq;
    RequestSequence m_sinksSeq;
};
