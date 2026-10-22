#include "Audio.h"

#include "MockAudioBackend.h"

#include <algorithm>

Audio::Audio(std::unique_ptr<AudioBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &AudioBackend::stateChanged, this, [this](int volume, bool muted) {
        m_wanted = volume;
        if (volume != m_volume) {
            m_volume = volume;
            emit volumeChanged();
        }
        if (muted != m_muted) {
            m_muted = muted;
            emit mutedChanged();
        }
        if (m_ready)
            emit adjusted();
        m_ready = true; // the first report is the initial read, not a change
    });
    m_backend->refresh();
}

Audio::~Audio() = default;

Audio *Audio::create(QQmlEngine *, QJSEngine *)
{
    return new Audio(std::make_unique<MockAudioBackend>());
}

void Audio::setVolume(int volume)
{
    m_wanted = std::clamp(volume, 0, 100);
    m_backend->setVolume(m_wanted);
}

void Audio::stepVolume(int delta)
{
    setVolume(m_wanted + delta);
}

void Audio::toggleMute()
{
    m_backend->setMuted(!m_muted);
}
