#pragma once

#include "AudioBackend.h"

#include <QStringList>

// In-memory audio: master volume 50, unmuted, every channel at 100; outputs "TV (HDMI)"
// (default) and "Analog output". The policy of spec 03 §2.3 is mirrored: a plugged-in headset
// (usb or bluetooth) becomes the default, and when the default goes away the previous default
// comes back.
class MockAudioBackend final : public AudioBackend
{
    Q_OBJECT

public:
    explicit MockAudioBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void setVolume(int volume) override;
    void setMuted(bool muted) override;
    void setChannelVolume(const QString &channel, int value) override;
    void setDefaultSink(const QString &id) override;

    // Tests only: "usb-headset" ("USB headset") and "bt-headphones" ("BT headphones").
    // Returns false for an unknown id; plugging a connected device in again does nothing.
    bool plug(const QString &id);
    void unplug(const QString &id);
    void reset();

private:
    void initState();
    void publishState();
    void publishSinks();
    int indexOf(const QString &id) const;
    void makeDefault(const QString &id);

    int m_volume = 50;
    bool m_muted = false;
    QVariantMap m_channels;
    QList<SinkInfo> m_sinks;
    QStringList m_previous; // earlier defaults, most recent last
};
