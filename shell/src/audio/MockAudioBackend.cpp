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
bool pluggableInput(const QString &id, InputInfo *out)
{
    if (id == QLatin1String("mic-0")) {
        *out = {id, QStringLiteral("Built-in microphone"), QStringLiteral("analog"), QStringLiteral("unknown"), false};
        return true;
    }
    if (id == QLatin1String("usb-mic")) {
        *out = {id, QStringLiteral("USB headset microphone"), QStringLiteral("usb"), QStringLiteral("unknown"), false};
        return true;
    }
    if (id == QLatin1String("bt-mic")) {
        *out = {id, QStringLiteral("BT headset microphone"), QStringLiteral("bluetooth"), QStringLiteral("unknown"), false};
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
    publishState(m_delay);
    publishSinks(m_delay);
    publishOutputs(m_delay);
    publishInputs(m_delay);
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
    if (known) {
        publishSinks();
        publishOutputs();
    }
}

// The mock's outputs: one per connected sink (the analog one is the speaker), plus the headphones
// jack of the card, which is empty and has no sink.
QList<OutputInfo> MockAudioBackend::outputs() const
{
    QList<OutputInfo> out;
    for (const SinkInfo &s : m_sinks) {
        OutputInfo o;
        o.id = s.id;
        o.name = s.name;
        o.kind = s.kind == QLatin1String("analog") ? QStringLiteral("speaker") : s.kind;
        o.available = s.kind == QLatin1String("analog") ? QStringLiteral("unknown") : QStringLiteral("yes");
        o.active = true;
        o.isDefault = s.isDefault;
        o.isSaved = s.id == m_saved;
        out.append(o);
    }
    OutputInfo jack;
    jack.id = QStringLiteral("headphones-0");
    jack.name = QStringLiteral("Headphones");
    jack.kind = QStringLiteral("headphones");
    jack.available = m_jackPlugged ? QStringLiteral("yes") : QStringLiteral("no");
    jack.isSaved = jack.id == m_saved;
    out.append(jack);
    return out;
}

void MockAudioBackend::setOutput(const QString &id)
{
    QString status = QStringLiteral("unknown-output");
    for (const OutputInfo &o : outputs()) {
        if (o.id != id)
            continue;
        status = o.active ? QStringLiteral("ok") : QStringLiteral("inactive");
        if (o.active) {
            m_saved = id;
            if (!o.isDefault)
                makeDefault(id);
        }
    }
    QTimer::singleShot(0, this, [this, id, status] { emit setOutputFinished(id, status); });
    if (status == QLatin1String("ok")) {
        publishSinks();
        publishOutputs();
    }
}

void MockAudioBackend::testOutput(const QString &id)
{
    QString status = QStringLiteral("unknown-output");
    for (const OutputInfo &o : outputs()) {
        if (o.id == id) {
            status = o.active ? QStringLiteral("ok") : QStringLiteral("inactive");
            if (o.active)
                m_tested.append(id);
        }
    }
    QTimer::singleShot(0, this, [this, id, status] { emit testOutputFinished(id, status); });
}

void MockAudioBackend::resetOutputChoice()
{
    m_saved.clear();
    publishOutputs();
}

QString MockAudioBackend::defaultInput() const
{
    for (const InputInfo &i : m_inputs) {
        if (i.isDefault)
            return i.id;
    }
    return {};
}

void MockAudioBackend::setInput(const QString &id)
{
    bool known = false;
    for (const InputInfo &i : std::as_const(m_inputs))
        known = known || i.id == id;
    if (known) {
        for (InputInfo &i : m_inputs)
            i.isDefault = i.id == id;
    }
    QTimer::singleShot(0, this, [this, id, known] {
        emit setInputFinished(id, known ? QStringLiteral("ok") : QStringLiteral("unknown-input"));
    });
    if (known) {
        publishInputs();
        publishState(); // the mute is the new default's
    }
}

void MockAudioBackend::setInputMuted(bool muted)
{
    const QString current = defaultInput();
    if (!current.isEmpty())
        m_inputMuted[current] = muted; // with no microphone a write changes nothing, like the service
    publishState();
}

bool MockAudioBackend::plugInput(const QString &id)
{
    InputInfo input;
    if (!pluggableInput(id, &input))
        return false;
    for (const InputInfo &i : std::as_const(m_inputs)) {
        if (i.id == id)
            return true;
    }
    input.isDefault = m_inputs.isEmpty();
    m_inputs.append(input);
    publishInputs();
    publishState();
    return true;
}

void MockAudioBackend::unplugInput(const QString &id)
{
    for (int at = 0; at < m_inputs.size(); ++at) {
        if (m_inputs.at(at).id != id)
            continue;
        const bool wasDefault = m_inputs.at(at).isDefault;
        m_inputs.removeAt(at);
        m_inputMuted.remove(id);
        if (wasDefault && !m_inputs.isEmpty())
            m_inputs.first().isDefault = true;
        publishInputs();
        publishState();
        return;
    }
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
        publishOutputs();
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
    publishOutputs();
}

void MockAudioBackend::reset()
{
    initState();
    publishState();
    publishSinks();
    publishOutputs();
    publishInputs();
}

// No publishing here: the constructor runs before anybody listens.
void MockAudioBackend::initState()
{
    m_volume = 50;
    m_muted = false;
    m_playing = false;
    m_channels.clear();
    for (const QString &name : channelNames())
        m_channels.insert(name, 100);
    m_sinks = {hdmi(), analog()};
    m_previous.clear();
    m_saved.clear();
    m_tested.clear();
    m_jackPlugged = false;
    m_inputs.clear();
    m_inputMuted.clear();
    InputInfo mic;
    pluggableInput(QStringLiteral("mic-0"), &mic);
    mic.isDefault = true;
    m_inputs.append(mic);
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
void MockAudioBackend::publishState(int delayMs)
{
    const int volume = m_volume;
    const bool muted = m_muted;
    const bool playing = m_playing;
    const QVariantMap channels = m_channels;
    const bool inputMuted = m_inputMuted.value(defaultInput(), false);
    const quint64 request = beginStateRequest();
    if (delayMs > 0)
        ++m_pending;
    QTimer::singleShot(delayMs, this, [this, request, volume, muted, playing, channels, inputMuted, delayMs] {
        if (delayMs > 0)
            --m_pending;
        if (deliverState(request, volume, muted, channels)) {
            emit playingReported(playing);
            emit inputMutedReported(inputMuted);
        }
    });
}

void MockAudioBackend::publishInputs(int delayMs)
{
    const QList<InputInfo> list = m_inputs;
    const quint64 request = beginInputsRequest();
    if (delayMs > 0)
        ++m_pending;
    QTimer::singleShot(delayMs, this, [this, request, list, delayMs] {
        if (delayMs > 0)
            --m_pending;
        deliverInputs(request, list);
    });
}

void MockAudioBackend::publishSinks(int delayMs)
{
    const QList<SinkInfo> sinks = m_sinks;
    const quint64 request = beginSinksRequest();
    if (delayMs > 0)
        ++m_pending;
    QTimer::singleShot(delayMs, this, [this, request, sinks, delayMs] {
        if (delayMs > 0)
            --m_pending;
        deliverSinks(request, sinks);
    });
}

void MockAudioBackend::publishOutputs(int delayMs)
{
    const QList<OutputInfo> list = outputs();
    const quint64 request = beginOutputsRequest();
    if (delayMs > 0)
        ++m_pending;
    QTimer::singleShot(delayMs, this, [this, request, list, delayMs] {
        if (delayMs > 0)
            --m_pending;
        deliverOutputs(request, list);
    });
}
