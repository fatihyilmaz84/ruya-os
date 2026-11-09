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
    connect(m_backend.get(), &AudioBackend::playingReported, this, [this](bool playing) {
        if (playing != m_playing) {
            m_playing = playing;
            emit playingChanged();
        }
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
    connect(m_backend.get(), &AudioBackend::outputsListed, this, [this](const QList<OutputInfo> &list) {
        QVariantList out;
        for (const OutputInfo &o : list) {
            out.append(QVariantMap{
                {QStringLiteral("id"), o.id},
                {QStringLiteral("name"), o.name},
                {QStringLiteral("kind"), o.kind},
                {QStringLiteral("card"), o.card},
                {QStringLiteral("port"), o.port},
                {QStringLiteral("available"), o.available},
                {QStringLiteral("active"), o.active},
                {QStringLiteral("isDefault"), o.isDefault},
                {QStringLiteral("isSaved"), o.isSaved},
            });
        }
        m_outputs = out;
        emit outputsChanged();
    });
    connect(m_backend.get(), &AudioBackend::setOutputFinished, this, &Audio::setOutputFinished);
    connect(m_backend.get(), &AudioBackend::testOutputFinished, this, &Audio::testOutputFinished);
    m_backend->refresh();
}

Audio::~Audio() = default;

Audio *Audio::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<AudioBackend> backend;
    // Like Profiles: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockAudioBackend>();
    else
        backend = std::make_unique<DBusAudioBackend>();
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

void Audio::setOutput(const QString &id)
{
    m_backend->setOutput(id);
}

void Audio::testOutput(const QString &id)
{
    m_backend->testOutput(id);
}

void Audio::resetOutputChoice()
{
    m_backend->resetOutputChoice();
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

void Audio::mockSetPlaying(bool playing)
{
    if (auto *mock = qobject_cast<MockAudioBackend *>(m_backend.get()))
        mock->setPlaying(playing);
}

void Audio::mockSetJackPlugged(bool plugged)
{
    if (auto *mock = qobject_cast<MockAudioBackend *>(m_backend.get()))
        mock->setJackPlugged(plugged);
}

void Audio::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockAudioBackend *>(m_backend.get())) {
        mock->setReplyDelay(ms);
        mock->refresh();
        mock->setReplyDelay(0);
    }
}

int Audio::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockAudioBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
