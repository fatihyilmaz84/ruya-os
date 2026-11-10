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

// One output of a sound card (Devices1.Audio ListOutputs, T-322).
struct OutputInfo
{
    QString id;
    QString name;
    QString kind;      // "speaker" | "headphones" | "hdmi" | "usb" | "bluetooth"
    QString card;
    QString port;
    QString available; // "yes" | "no" | "unknown"
    bool active = false; // a sink exists for it (its card profile is the active one)
    bool isDefault = false;
    bool isSaved = false; // the player's choice (SetOutput)
};

// One microphone (Devices1.Audio ListInputs, T-449).
struct InputInfo
{
    QString id;
    QString name;
    QString kind;      // "analog" | "usb" | "bluetooth"
    QString available; // "yes" | "no" | "unknown"
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
    // The player's choice (kept by the service over reboots), a short tone on one output without
    // changing the default, and forgetting the choice. Results: setOutputFinished,
    // testOutputFinished, and a new outputsListed.
    virtual void setOutput(const QString &id) = 0;
    virtual void testOutput(const QString &id) = 0;
    virtual void resetOutputChoice() = 0;
    // Microphones (T-449): make a listed one the default; mute the default one. Results:
    // setInputFinished, a new inputsListed, and inputMutedReported with the next state report.
    virtual void setInput(const QString &id) = 0;
    virtual void setInputMuted(bool muted) = 0;

signals:
    // channels: channel name -> 0-100, all channels of channelNames().
    void stateChanged(int volume, bool muted, const QVariantMap &channels);
    // Something plays through an output (Devices1.Audio Playing, T-202). Sent with every accepted
    // state report that carries it.
    void playingReported(bool playing);
    void sinksListed(const QList<SinkInfo> &sinks);
    // status: see the XML ("ok", "unknown-sink", "failed").
    void setDefaultSinkFinished(const QString &id, const QString &status);
    void outputsListed(const QList<OutputInfo> &outputs);
    // status: "ok", "unknown-output", "inactive", "failed" (see the XML).
    void setOutputFinished(const QString &id, const QString &status);
    void testOutputFinished(const QString &id, const QString &status);
    void inputsListed(const QList<InputInfo> &inputs);
    // Mute of the default microphone (Devices1.Audio InputMuted); sent with every accepted state report.
    void inputMutedReported(bool muted);
    // status: "ok", "unknown-input", "failed" (see the XML).
    void setInputFinished(const QString &id, const QString &status);

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

    quint64 beginOutputsRequest() { return m_outputsSeq.begin(); }
    void deliverOutputs(quint64 request, const QList<OutputInfo> &outputs)
    {
        if (m_outputsSeq.accept(request))
            emit outputsListed(outputs);
    }

    quint64 beginInputsRequest() { return m_inputsSeq.begin(); }
    void deliverInputs(quint64 request, const QList<InputInfo> &inputs)
    {
        if (m_inputsSeq.accept(request))
            emit inputsListed(inputs);
    }

private:
    RequestSequence m_inputsSeq;
    RequestSequence m_outputsSeq;
    RequestSequence m_stateSeq;
    RequestSequence m_sinksSeq;
};
