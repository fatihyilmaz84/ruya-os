#include "Audio.h"

#include "DBusAudioBackend.h"
#include "MockAudioBackend.h"

#include <algorithm>

Audio::Audio(std::unique_ptr<AudioBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    // Before the first report the channels read as "full", so nothing is silenced by default.
    for (const QString &name : AudioBackend::channelNames())
        m_channels.insert(name, 100);

    connect(m_backend.get(), &AudioBackend::stateChanged, this,
            [this](int volume, bool muted, const QVariantMap &channels) {
                // Report what the OSD shows (master level and mute): a change, or the answer to a
                // master command that changed nothing. A channel command alone is not one.
                const bool masterReport = m_masterPending || volume != m_volume || muted != m_muted;
                m_masterPending = false;
                m_wanted = volume;
                m_wantedMuted = muted;
                if (volume != m_volume) {
                    m_volume = volume;
                    emit volumeChanged();
                }
                if (muted != m_muted) {
                    m_muted = muted;
                    emit mutedChanged();
                }
                if (channels != m_channels) {
                    m_channels = channels;
                    emit channelVolumesChanged();
                }
                if (m_ready && masterReport)
                    emit adjusted();
                m_ready = true; // the first report is the initial read, not a change
            });
    connect(m_backend.get(), &AudioBackend::sinksListed, this, [this](const QList<SinkInfo> &list) {
        QVariantList out;
        QString defaultId;
        QString defaultName;
        for (const SinkInfo &s : list) {
            out.append(QVariantMap{
                {QStringLiteral("id"), s.id},
                {QStringLiteral("name"), s.name},
                {QStringLiteral("kind"), s.kind},
                {QStringLiteral("isDefault"), s.isDefault},
            });
            if (s.isDefault) {
                defaultId = s.id;
                defaultName = s.name;
            }
        }
        const bool switched = defaultId != m_defaultSink;
        const bool changed = switched || defaultName != m_defaultSinkName;
        m_sinks = out;
        m_defaultSink = defaultId;
        m_defaultSinkName = defaultName;
        emit sinksChanged();
        if (changed)
            emit defaultSinkChanged();
        if (m_sinksReady && switched && !defaultId.isEmpty())
            emit outputSwitched();
        m_sinksReady = true; // the first list is the initial read
    });
    connect(m_backend.get(), &AudioBackend::setDefaultSinkFinished, this, &Audio::setDefaultSinkFinished);
    m_backend->refresh();
}

Audio::~Audio() = default;

Audio *Audio::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<AudioBackend> backend;
    if (qEnvironmentVariable("RUYA_SERVICES") == QLatin1String("dbus"))
        backend = std::make_unique<DBusAudioBackend>();
    else
        backend = std::make_unique<MockAudioBackend>();
    return new Audio(std::move(backend));
}

void Audio::setVolume(int volume)
{
    m_wanted = std::clamp(volume, 0, 100);
    m_masterPending = true;
    m_backend->setVolume(m_wanted);
}

void Audio::stepVolume(int delta)
{
    if (m_wantedMuted) {
        if (delta < 0) {
            emit adjusted(); // stays muted; the OSD shows that
            return;
        }
        setMuted(false);
    }
    setVolume(m_wanted + delta);
}

void Audio::toggleMute()
{
    setMuted(!m_wantedMuted);
}

void Audio::setMuted(bool muted)
{
    m_wantedMuted = muted;
    m_masterPending = true;
    m_backend->setMuted(muted);
}

void Audio::setChannelVolume(const QString &channel, int value)
{
    if (!AudioBackend::channelNames().contains(channel)) {
        qWarning("ruya-shell: audio: unknown channel '%s'", qPrintable(channel));
        return;
    }
    m_backend->setChannelVolume(channel, std::clamp(value, 0, 100));
}

void Audio::setDefaultSink(const QString &id)
{
    m_backend->setDefaultSink(id);
}

bool Audio::mockPlug(const QString &id)
{
    auto *mock = qobject_cast<MockAudioBackend *>(m_backend.get());
    return mock && mock->plug(id);
}

void Audio::mockUnplug(const QString &id)
{
    if (auto *mock = qobject_cast<MockAudioBackend *>(m_backend.get()))
        mock->unplug(id);
}

void Audio::mockReset()
{
    if (auto *mock = qobject_cast<MockAudioBackend *>(m_backend.get()))
        mock->reset();
}
