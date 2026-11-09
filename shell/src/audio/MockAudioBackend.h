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
    void setOutput(const QString &id) override;
    void testOutput(const QString &id) override;
    void resetOutputChoice() override;

    // Tests only: "usb-headset" ("USB headset") and "bt-headphones" ("BT headphones").
    // Returns false for an unknown id; plugging a connected device in again does nothing.
    bool plug(const QString &id);
    void unplug(const QString &id);
    // The outputs a test sound was asked for, in order (tests).
    QStringList testedOutputs() const { return m_tested; }
    void reset();
    void setPlaying(bool playing)
    {
        m_playing = playing;
        publishState();
    }
    // Replies to refresh() arrive after `ms` (0: at once), with the state as it was when asked;
    // the number of replies still on their way. Lets a test play an old reply landing after a
    // new one.
    void setReplyDelay(int ms) { m_delay = ms; }
    int pendingReplies() const { return m_pending; }

private:
    void initState();
    void publishState(int delayMs = 0);
    void publishSinks(int delayMs = 0);
    void publishOutputs(int delayMs = 0);
    QList<OutputInfo> outputs() const;
    int indexOf(const QString &id) const;
    void makeDefault(const QString &id);

    int m_volume = 50;
    bool m_muted = false;
    bool m_playing = false;
    QVariantMap m_channels;
    QList<SinkInfo> m_sinks;
    QString m_saved; // the player's choice (an output id)
    QStringList m_tested;
    QStringList m_previous; // earlier defaults, most recent last
    int m_delay = 0;
    int m_pending = 0;
};
