#pragma once

#include "AudioBackend.h"

// In-memory master volume: starts at 50, unmuted.
class MockAudioBackend final : public AudioBackend
{
    Q_OBJECT

public:
    explicit MockAudioBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void setVolume(int volume) override;
    void setMuted(bool muted) override;

private:
    void publish();

    int m_volume = 50;
    bool m_muted = false;
};
