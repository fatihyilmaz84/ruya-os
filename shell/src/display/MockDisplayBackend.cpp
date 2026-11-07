#include "MockDisplayBackend.h"

#include <QTimer>

MockDisplayBackend::MockDisplayBackend(QObject *parent)
    : DisplayBackend(parent)
{
    useScenario(QStringLiteral("tv4k"));
}

bool MockDisplayBackend::useScenario(const QString &name)
{
    // Kernel order: the preferred mode first, then larger and faster ones first.
    if (name == QLatin1String("tv4k")) {
        m_screen = {QStringLiteral("HDMI-A-1"), QStringLiteral("Living room TV"), 1220, 690,
                    {{3840, 2160, 60000, true}, {3840, 2160, 30000, false}, {2560, 1440, 60000, false},
                     {1920, 1080, 60000, false}, {1920, 1080, 50000, false}, {1920, 1080, 24000, false},
                     {1280, 720, 60000, false}}};
    } else if (name == QLatin1String("tv1080")) {
        m_screen = {QStringLiteral("HDMI-A-2"), QStringLiteral("Bedroom TV"), 885, 498,
                    {{1920, 1080, 60000, true}, {1920, 1080, 50000, false}, {1280, 720, 60000, false},
                     {1024, 768, 0, false}}};
    } else if (name == QLatin1String("monitor")) {
        m_screen = {QStringLiteral("DP-1"), QStringLiteral("DELL U3223QE"), 698, 393,
                    {{3840, 2160, 60000, true}, {2560, 1440, 60000, false}, {1920, 1080, 60000, false},
                     {1920, 1080, 30000, false}}};
    } else if (name == QLatin1String("none")) {
        m_screen = {};      // nothing connected, or the service is not there: the screen rows go away
    } else {
        return false;
    }
    m_stored = -1;
    m_candidate = {};
    m_fallback = false;
    publish();
    return true;
}

void MockDisplayBackend::reset()
{
    m_uiScale = 0;
    m_failNext = false;
    m_restarts = 0;
    m_setModeCalls = 0;
    useScenario(QStringLiteral("tv4k"));
}

int MockDisplayBackend::defaultIndex() const
{
    for (int i = 0; i < m_screen.modes.size(); ++i) {
        if (m_screen.modes.at(i).preferred)
            return i;
    }
    return 0;
}

int MockDisplayBackend::currentIndex() const
{
    return m_stored >= 0 ? m_stored : defaultIndex();
}

QVariantList MockDisplayBackend::outputsNow() const
{
    if (m_screen.id.isEmpty())
        return {};
    QVariantList modes;
    const int current = currentIndex();
    for (int i = 0; i < m_screen.modes.size(); ++i) {
        const Mode &m = m_screen.modes.at(i);
        modes.append(QVariantMap{{QStringLiteral("width"), m.width},
                                 {QStringLiteral("height"), m.height},
                                 {QStringLiteral("refreshMhz"), m.refreshMhz},
                                 {QStringLiteral("preferred"), m.preferred},
                                 {QStringLiteral("current"), i == current}});
    }
    return {QVariantMap{{QStringLiteral("id"), m_screen.id},
                        {QStringLiteral("name"), m_screen.name},
                        {QStringLiteral("widthMm"), m_screen.widthMm},
                        {QStringLiteral("heightMm"), m_screen.heightMm},
                        {QStringLiteral("modes"), modes}}};
}

QVariantMap MockDisplayBackend::pendingNow() const
{
    if (!m_candidate.valid)
        return {};
    return {{QStringLiteral("output"), m_screen.id},
            {QStringLiteral("width"), m_candidate.width},
            {QStringLiteral("height"), m_candidate.height},
            {QStringLiteral("refreshMhz"), m_candidate.refreshMhz},
            {QStringLiteral("starts"), m_candidate.starts}};
}

void MockDisplayBackend::publish()
{
    deliverState(beginStateRequest(), outputsNow(), pendingNow(), m_uiScale);
}

void MockDisplayBackend::refresh()
{
    publish();
}

void MockDisplayBackend::refreshDelayed(int ms)
{
    const quint64 request = beginStateRequest();
    ++m_pending;
    QTimer::singleShot(ms, this, [this, request, outputs = outputsNow(), pending = pendingNow(), scale = m_uiScale] {
        --m_pending;
        deliverState(request, outputs, pending, scale);
    });
}

void MockDisplayBackend::setMode(const QString &output, uint width, uint height, uint refreshMhz)
{
    ++m_setModeCalls;
    QTimer::singleShot(0, this, [this, output, width, height, refreshMhz] {
        QString status = QStringLiteral("ok");
        int at = -1;
        for (int i = 0; i < m_screen.modes.size(); ++i) {
            const Mode &m = m_screen.modes.at(i);
            if (m.width == width && m.height == height && m.refreshMhz == refreshMhz)
                at = i;
        }
        if (output != m_screen.id) {
            status = QStringLiteral("unknown-output");
        } else if (at < 0) {
            status = QStringLiteral("unknown-mode");
        } else if (m_candidate.valid) {
            status = QStringLiteral("busy");
        } else if (at == currentIndex()) {
            status = QStringLiteral("unchanged");
        } else if (m_failNext) {
            m_failNext = false;
            status = QStringLiteral("failed");
        } else {
            m_candidate = {width, height, refreshMhz, 0, true};
            publish();
        }
        emit setModeFinished(status);
    });
}

void MockDisplayBackend::keep()
{
    QTimer::singleShot(0, this, [this] {
        if (!m_candidate.valid) {
            emit keepFinished(QStringLiteral("no-pending"));
            return;
        }
        for (int i = 0; i < m_screen.modes.size(); ++i) {
            const Mode &m = m_screen.modes.at(i);
            if (m.width == m_candidate.width && m.height == m_candidate.height && m.refreshMhz == m_candidate.refreshMhz)
                m_stored = i;
        }
        m_candidate = {};
        publish();
        emit keepFinished(QStringLiteral("ok"));
    });
}

void MockDisplayBackend::revert()
{
    QTimer::singleShot(0, this, [this] {
        if (!m_candidate.valid) {
            emit revertFinished(QStringLiteral("no-pending"));
            return;
        }
        m_candidate = {};
        publish();
        emit revertFinished(QStringLiteral("ok"));
    });
}

void MockDisplayBackend::setUiScale(int percent)
{
    QTimer::singleShot(0, this, [this, percent] {
        if (percent != 0 && percent != 100 && percent != 125 && percent != 150 && percent != 200) {
            emit setUiScaleFinished(QStringLiteral("invalid"));
            return;
        }
        m_uiScale = percent;
        publish();
        emit setUiScaleFinished(QStringLiteral("ok"));
    });
}

void MockDisplayBackend::takeFallbackNotice()
{
    QTimer::singleShot(0, this, [this] {
        const bool happened = m_fallback;
        m_fallback = false;
        emit fallbackNoticeReported(happened);
    });
}

void MockDisplayBackend::restartShell()
{
    ++m_restarts;
    // The shell is back: a change that waited counts its first start, as the service's guard does.
    if (m_candidate.valid && m_candidate.starts == 0) {
        m_candidate.starts = 1;
        QTimer::singleShot(0, this, [this] { publish(); });
    }
}

void MockDisplayBackend::simulateFallback()
{
    // A second start with the marker still there: the choice is dropped, the preferred mode is back.
    m_candidate = {};
    m_stored = -1;
    m_fallback = true;
    publish();
}
