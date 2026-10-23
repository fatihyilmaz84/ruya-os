#include "MockAudioBackend.h"

#include <QTimer>

#include <algorithm>

namespace {
SinkInfo hdmi()
{
    return {QStringLiteral("hdmi-0"), QStringLiteral("TV (HDMI)"), QStringLiteral("hdmi"), true};
}
SinkInfo analog()
{
    return {QStringLiteral("analog-0"), QStringLiteral("Analog output"), QStringLiteral("analog"), false};
}
// The devices the tests can plug in.
bool pluggable(const QString &id, SinkInfo *out)
{
    if (id == QLatin1String("usb-headset")) {
        *out = {id, QStringLiteral("USB headset"), QStringLiteral("usb"), false};
        return true;
    }
    if (id == QLatin1String("bt-headphones")) {
        *out = {id, QStringLiteral("BT headphones"), QStringLiteral("bluetooth"), false};
        return true;
    }
    return false;
}
} // namespace

MockAudioBackend::MockAudioBackend(QObject *parent)
    : AudioBackend(parent)
{
    initState();
}

void MockAudioBackend::refresh()
{
    publishState();
    publishSinks();
}

void MockAudioBackend::setVolume(int volume)
{
    m_volume = std::clamp(volume, 0, 100);
    publishState();
}

void MockAudioBackend::setMuted(bool muted)
{
    m_muted = muted;
    publishState();
}

void MockAudioBackend::setChannelVolume(const QString &channel, int value)
{
    if (channelNames().contains(channel))
        m_channels[channel] = std::clamp(value, 0, 100);
    publishState();
}

void MockAudioBackend::setDefaultSink(const QString &id)
{
    const bool known = indexOf(id) >= 0;
    if (known && !m_sinks.at(indexOf(id)).isDefault)
        makeDefault(id);
    QTimer::singleShot(0, this, [this, id, known] {
        emit setDefaultSinkFinished(id, known ? QStringLiteral("ok") : QStringLiteral("unknown-sink"));
    });
    if (known)
        publishSinks();
}

bool MockAudioBackend::plug(const QString &id)
{
    SinkInfo sink;
    if (!pluggable(id, &sink))
        return false;
    if (indexOf(id) < 0) {
        m_sinks.append(sink);
        makeDefault(id); // a new headset becomes the default
        publishSinks();
    }
    return true;
}

void MockAudioBackend::unplug(const QString &id)
{
    const int at = indexOf(id);
    if (at < 0)
        return;
    const bool wasDefault = m_sinks.at(at).isDefault;
    m_sinks.removeAt(at);
    m_previous.removeAll(id);
    if (wasDefault) {
        // Back to the most recent earlier default that is still connected, else the first output.
        QString next;
        while (!m_previous.isEmpty() && next.isEmpty()) {
            const QString candidate = m_previous.takeLast();
            if (indexOf(candidate) >= 0)
                next = candidate;
        }
        if (next.isEmpty() && !m_sinks.isEmpty())
            next = m_sinks.constFirst().id;
        for (SinkInfo &s : m_sinks)
            s.isDefault = s.id == next;
    }
    publishSinks();
}

void MockAudioBackend::reset()
{
    initState();
    publishState();
    publishSinks();
}

// No publishing here: the constructor runs before anybody listens.
void MockAudioBackend::initState()
{
    m_volume = 50;
    m_muted = false;
    m_channels.clear();
    for (const QString &name : channelNames())
        m_channels.insert(name, 100);
    m_sinks = {hdmi(), analog()};
    m_previous.clear();
}

int MockAudioBackend::indexOf(const QString &id) const
{
    for (int i = 0; i < m_sinks.size(); ++i) {
        if (m_sinks.at(i).id == id)
            return i;
    }
    return -1;
}

// Remember the old default as "previous", then switch.
void MockAudioBackend::makeDefault(const QString &id)
{
    for (const SinkInfo &s : std::as_const(m_sinks)) {
        if (s.isDefault && s.id != id) {
            m_previous.removeAll(s.id);
            m_previous.append(s.id);
        }
    }
    m_previous.removeAll(id);
    for (SinkInfo &s : m_sinks)
        s.isDefault = s.id == id;
}

// Asynchronous like the real service, so QML behaves the same with either backend.
void MockAudioBackend::publishState()
{
    const int volume = m_volume;
    const bool muted = m_muted;
    const QVariantMap channels = m_channels;
    QTimer::singleShot(0, this, [this, volume, muted, channels] { emit stateChanged(volume, muted, channels); });
}

void MockAudioBackend::publishSinks()
{
    const QList<SinkInfo> sinks = m_sinks;
    QTimer::singleShot(0, this, [this, sinks] { emit sinksListed(sinks); });
}
