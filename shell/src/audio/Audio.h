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
    // channel name ("ui", "ambient", "media") -> 0-100
    Q_PROPERTY(QVariantMap channelVolumes READ channelVolumes NOTIFY channelVolumesChanged)
    // [{ id, name, kind, isDefault }]
    Q_PROPERTY(QVariantList sinks READ sinks NOTIFY sinksChanged)
    Q_PROPERTY(QString defaultSink READ defaultSink NOTIFY defaultSinkChanged)
    Q_PROPERTY(QString defaultSinkName READ defaultSinkName NOTIFY defaultSinkChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Audio(std::unique_ptr<AudioBackend> backend, QObject *parent = nullptr);
    ~Audio() override;

    static Audio *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    int volume() const { return m_volume; }
    bool isMuted() const { return m_muted; }
    QVariantMap channelVolumes() const { return m_channels; }
    QVariantList sinks() const { return m_sinks; }
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

    // Tests only, and only with the mock backend (otherwise no-ops; mockPlug returns false):
    // plug in / remove "usb-headset" or "bt-headphones", or restore the initial state.
    Q_INVOKABLE bool mockPlug(const QString &id);
    Q_INVOKABLE void mockUnplug(const QString &id);
    Q_INVOKABLE void mockReset();

signals:
    void volumeChanged();
    void mutedChanged();
    void channelVolumesChanged();
    void sinksChanged();
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

private:
    std::unique_ptr<AudioBackend> m_backend;
    int m_volume = 0;
    int m_wanted = 0; // last requested level, so rapid steps accumulate before results arrive
    bool m_muted = false;
    bool m_wantedMuted = false;
    bool m_ready = false;
    bool m_masterPending = false; // a master command is waiting for its report
    bool m_sinksReady = false;
    QVariantMap m_channels;
    QVariantList m_sinks;
    QString m_defaultSink;
    QString m_defaultSinkName;
};
