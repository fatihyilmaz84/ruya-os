#include "MockAudioBackend.h"

#include <QTimer>

#include <algorithm>

MockAudioBackend::MockAudioBackend(QObject *parent)
    : AudioBackend(parent)
{
}

void MockAudioBackend::refresh()
{
    publish();
}

void MockAudioBackend::setVolume(int volume)
{
    m_volume = std::clamp(volume, 0, 100);
    publish();
}

void MockAudioBackend::setMuted(bool muted)
{
    m_muted = muted;
    publish();
}

// Asynchronous like the real service, so QML behaves the same with either backend.
void MockAudioBackend::publish()
{
    const int volume = m_volume;
    const bool muted = m_muted;
    QTimer::singleShot(0, this, [this, volume, muted] { emit stateChanged(volume, muted); });
}
