#pragma once

#include "AudioBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// QML face of org.ruyaos.Devices1.Audio: master volume and mute, the channel volumes and the
// outputs (sinks). Backend: RUYA_SERVICES=mock|dbus. Unlike the other services this defaults
// to the mock on every OS, because the D-Bus service (ruya-devices, blocker B-007) does not
// exist yet; flip the default to follow Profiles once it does.
class Audio : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(int volume READ volume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ isMuted NOTIFY mutedChanged)
    // Something plays through an output (T-202): the idle clock does not count that as idle.
    Q_PROPERTY(bool playing READ isPlaying NOTIFY playingChanged)
    // channel name ("ui", "ambient", "media") -> 0-100
    Q_PROPERTY(QVariantMap channelVolumes READ channelVolumes NOTIFY channelVolumesChanged)
    // [{ id, name, kind, isDefault }]
    Q_PROPERTY(QVariantList sinks READ sinks NOTIFY sinksChanged)
    // Every output of the cards (T-322): [{ id, name, kind, card, port, available, active, isDefault, isSaved }]
    Q_PROPERTY(QVariantList outputs READ outputs NOTIFY outputsChanged)
    Q_PROPERTY(QString defaultSink READ defaultSink NOTIFY defaultSinkChanged)
    Q_PROPERTY(QString defaultSinkName READ defaultSinkName NOTIFY defaultSinkChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Audio(std::unique_ptr<AudioBackend> backend, QObject *parent = nullptr);
    ~Audio() override;

    static Audio *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    int volume() const { return m_volume; }
    bool isMuted() const { return m_muted; }
    bool isPlaying() const { return m_playing; }
    QVariantMap channelVolumes() const { return m_channels; }
    QVariantList sinks() const { return m_sinks; }
    QVariantList outputs() const { return m_outputs; }
    QString defaultSink() const { return m_defaultSink; }
    QString defaultSinkName() const { return m_defaultSinkName; }
    bool isMock() const { return m_backend->isMock(); }

    Q_INVOKABLE void setVolume(int volume);
    // Volume keys. Up while muted unmutes and raises; Down while muted changes nothing (it
    // stays muted) but still reports, so the OSD shows "Muted".
    Q_INVOKABLE void stepVolume(int delta);
    Q_INVOKABLE void toggleMute();
    Q_INVOKABLE void setMuted(bool muted);
    // channel: "ui" | "ambient" | "media"; value is clamped to 0-100. An unknown channel is ignored.
    Q_INVOKABLE void setChannelVolume(const QString &channel, int value);
    Q_INVOKABLE void setDefaultSink(const QString &id);
    // The player's choice, remembered by the service; a test sound on one output (the default is
    // not changed); forgetting the choice. Results: setOutputFinished / testOutputFinished.
    Q_INVOKABLE void setOutput(const QString &id);
    Q_INVOKABLE void testOutput(const QString &id);
    Q_INVOKABLE void resetOutputChoice();

    // Tests only, and only with the mock backend (otherwise no-ops; mockPlug returns false):
    // plug in / remove "usb-headset" or "bt-headphones", or restore the initial state.
    Q_INVOKABLE bool mockPlug(const QString &id);
    Q_INVOKABLE void mockUnplug(const QString &id);
    Q_INVOKABLE void mockReset();
    // The mock's `playing` flag (tests); a no-op against the service.
    Q_INVOKABLE void mockSetPlaying(bool playing);
    // Asks the backend for the state and the outputs; the replies arrive after `ms` and show them
    // as they are now. mockPendingReplies: how many are still on their way.
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;

signals:
    void volumeChanged();
    void mutedChanged();
    void playingChanged();
    void channelVolumesChanged();
    void sinksChanged();
    void outputsChanged();
    void defaultSinkChanged();
    // The master volume or mute was reported after a command or from outside (not the initial
    // read): what the volume OSD listens to. Also fires when a master command changed nothing
    // (e.g. Up at 100); a channel volume alone does not.
    void adjusted();
    // The default output changed after the initial read (by policy, by the user or from
    // outside): what the "Audio output: ..." toast listens to.
    void outputSwitched();
    // status: see api/dbus/org.ruyaos.Devices1.xml
    void setDefaultSinkFinished(const QString &id, const QString &status);
    // status: "ok", "unknown-output", "inactive", "failed"
    void setOutputFinished(const QString &id, const QString &status);
    void testOutputFinished(const QString &id, const QString &status);

private:
    std::unique_ptr<AudioBackend> m_backend;
    int m_volume = 0;
    int m_wanted = 0; // last requested level, so rapid steps accumulate before results arrive
    bool m_muted = false;
    bool m_playing = false;
    bool m_wantedMuted = false;
    bool m_ready = false;
    bool m_masterPending = false; // a master command is waiting for its report
    bool m_sinksReady = false;
    QVariantMap m_channels;
    QVariantList m_sinks;
    QVariantList m_outputs;
    QString m_defaultSink;
    QString m_defaultSinkName;
};
