#include "Display.h"

#include "DBusDisplayBackend.h"
#include "MockDisplayBackend.h"

#include <QVariantMap>

#include <algorithm>
#include <cmath>

namespace {
// The reference of the design (04 §1): a 55" 16:9 TV, 685 mm high, read from 3 m. Its UI unit is
// height / 1080. A monitor read from a desk gets a smaller factor, so that the UI keeps the angular
// size it has on the TV; nothing is enlarged (the layouts are made for 1080 design pixels of
// height and do not make room for more). The distance is a guess from the size: 0.8 m up to 27",
// 3 m from 42" on, in between a straight line.
constexpr qreal ReferenceHeightMm = 685.0;
constexpr qreal ReferenceDistanceM = 3.0;
constexpr qreal DeskDistanceM = 0.8;        // a monitor of 27" or less is read from a desk
constexpr qreal DeskDiagonalIn = 27.0;
constexpr qreal TvDiagonalIn = 42.0;        // from here on the screen is read from the sofa
constexpr qreal MinAutoScale = 0.5;

int intOf(const QVariantMap &m, const char *key)
{
    return m.value(QLatin1String(key)).toInt();
}
} // namespace

DisplayControl::DisplayControl(std::unique_ptr<DisplayBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &DisplayBackend::stateChanged, this, &DisplayControl::applyState);
    connect(m_backend.get(), &DisplayBackend::setModeFinished, this, [this](const QString &status) {
        // The service wrote the config and the marker: have the shell start again on the new mode.
        if (status == QLatin1String("ok"))
            m_backend->restartShell();
        emit setModeFinished(status);
    });
    connect(m_backend.get(), &DisplayBackend::keepFinished, this, &DisplayControl::keepFinished);
    connect(m_backend.get(), &DisplayBackend::revertFinished, this, [this](const QString &status) {
        // Back to the stored mode: the shell starts again to show it. Also when the service did not
        // answer or failed: the mode on trial may be on screen (or not), and the guard puts things
        // right at the next start (a marker still there is dropped, else the config is rewritten from
        // the stored choice). Only "nothing was pending" needs no restart.
        if (status != QLatin1String("no-pending"))
            m_backend->restartShell();
        emit revertFinished(status);
    });
    connect(m_backend.get(), &DisplayBackend::resetFinished, this, [this](const QString &status) {
        // The mode is the preferred one at the next start.
        if (status == QLatin1String("ok"))
            m_backend->restartShell();
        emit resetFinished(status);
    });
    connect(m_backend.get(), &DisplayBackend::fallbackNoticeReported, this, [this](bool happened) {
        if (happened)
            emit modeReset();
    });
    m_backend->refresh();
    m_backend->takeFallbackNotice();
}

DisplayControl::~DisplayControl() = default;

DisplayControl *DisplayControl::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<DisplayBackend> backend;
    // Like Network and Batteries: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockDisplayBackend>();
    else
        backend = std::make_unique<DBusDisplayBackend>();
    return new DisplayControl(std::move(backend));
}

qreal DisplayControl::autoScaleFor(int widthMm, int heightMm)
{
    if (widthMm <= 0 || heightMm <= 0)
        return 1.0;
    const qreal diagonalIn = std::hypot(static_cast<qreal>(widthMm), static_cast<qreal>(heightMm)) / 25.4;
    // A TV is read from the sofa, and the bigger it is the farther away: the UI stays a fixed
    // fraction of the screen (the 1080p unit as it is).
    if (diagonalIn >= TvDiagonalIn)
        return 1.0;
    qreal distance = DeskDistanceM;
    if (diagonalIn > DeskDiagonalIn)
        distance = DeskDistanceM
            + (diagonalIn - DeskDiagonalIn) / (TvDiagonalIn - DeskDiagonalIn) * (ReferenceDistanceM - DeskDistanceM);
    const qreal factor = (ReferenceHeightMm / heightMm) * (distance / ReferenceDistanceM);
    // In steps of 5 %, so that a TV a few millimetres off the reference is 100 %.
    return std::clamp(std::round(factor * 20.0) / 20.0, MinAutoScale, 1.0);
}

void DisplayControl::applyState(const QVariantList &outputs, const QVariantMap &pending, int uiScale)
{
    const QVariantMap first = outputs.isEmpty() ? QVariantMap() : outputs.constFirst().toMap();
    const QString id = first.value(QStringLiteral("id")).toString();
    const QVariantList modes = first.value(QStringLiteral("modes")).toList();
    const int widthMm = intOf(first, "widthMm");
    const int heightMm = intOf(first, "heightMm");

    // The distinct sizes in order, and the mode in use.
    QVariantList sizes;
    int curW = 0, curH = 0, curR = 0, prefW = 0, prefH = 0;
    for (const QVariant &v : modes) {
        const QVariantMap m = v.toMap();
        const int w = intOf(m, "width");
        const int h = intOf(m, "height");
        if (m.value(QStringLiteral("current")).toBool()) {
            curW = w;
            curH = h;
            curR = intOf(m, "refreshMhz");
        }
        if (m.value(QStringLiteral("preferred")).toBool()) {
            prefW = w;
            prefH = h;
        }
        bool known = false;
        for (const QVariant &s : std::as_const(sizes)) {
            const QVariantMap sm = s.toMap();
            known = known || (intOf(sm, "width") == w && intOf(sm, "height") == h);
        }
        if (!known)
            sizes.append(QVariantMap{{QStringLiteral("width"), w}, {QStringLiteral("height"), h}});
    }
    for (QVariant &s : sizes) {
        QVariantMap sm = s.toMap();
        sm.insert(QStringLiteral("preferred"), intOf(sm, "width") == prefW && intOf(sm, "height") == prefH);
        sm.insert(QStringLiteral("current"), intOf(sm, "width") == curW && intOf(sm, "height") == curH);
        s = sm;
    }

    const bool outputsDiffer = id != m_outputId || first.value(QStringLiteral("name")).toString() != m_outputName
        || widthMm != m_widthMm || heightMm != m_heightMm || modes != m_modes;
    m_outputId = id;
    m_outputName = first.value(QStringLiteral("name")).toString();
    m_widthMm = widthMm;
    m_heightMm = heightMm;
    m_modes = modes;
    m_resolutions = sizes;
    m_currentWidth = curW;
    m_currentHeight = curH;
    m_currentRefresh = curR;
    m_preferredWidth = prefW;
    m_preferredHeight = prefH;

    const int pw = intOf(pending, "width");
    const int ph = intOf(pending, "height");
    const int pr = intOf(pending, "refreshMhz");
    const int ps = intOf(pending, "starts");
    const bool pendingDiffers = pw != m_pendingWidth || ph != m_pendingHeight || pr != m_pendingRefresh
        || ps != m_pendingStarts;
    m_pendingWidth = pw;
    m_pendingHeight = ph;
    m_pendingRefresh = pr;
    m_pendingStarts = ps;

    const qreal before = uiScaleFactor();
    const int scaleBefore = m_uiScale;
    m_uiScale = uiScale;
    m_autoScale = autoScaleFor(widthMm, heightMm);

    if (outputsDiffer)
        emit outputsChanged();
    if (pendingDiffers)
        emit pendingChanged();
    if (scaleBefore != m_uiScale || !qFuzzyCompare(before, uiScaleFactor()))
        emit uiScaleChanged();
}

QVariantList DisplayControl::refreshRates(int width, int height) const
{
    QVariantList out;
    for (const QVariant &v : m_modes) {
        const QVariantMap m = v.toMap();
        if (intOf(m, "width") != width || intOf(m, "height") != height)
            continue;
        out.append(QVariantMap{{QStringLiteral("refreshMhz"), intOf(m, "refreshMhz")},
                               {QStringLiteral("preferred"), m.value(QStringLiteral("preferred")).toBool()},
                               {QStringLiteral("current"), m.value(QStringLiteral("current")).toBool()}});
    }
    return out;
}

void DisplayControl::requestMode(int width, int height, int refreshMhz)
{
    if (m_outputId.isEmpty() || pending()) {
        emit setModeFinished(m_outputId.isEmpty() ? QStringLiteral("unknown-output") : QStringLiteral("busy"));
        return;
    }
    m_backend->setMode(m_outputId, static_cast<uint>(width), static_cast<uint>(height), static_cast<uint>(refreshMhz));
}

void DisplayControl::chooseResolution(int width, int height)
{
    const QVariantList rates = refreshRates(width, height);
    if (rates.isEmpty()) {
        emit setModeFinished(QStringLiteral("unknown-mode"));
        return;
    }
    // Keep the refresh rate if the new size has it, else the size's first (preferred or fastest).
    int chosen = intOf(rates.constFirst().toMap(), "refreshMhz");
    for (const QVariant &r : rates) {
        if (intOf(r.toMap(), "refreshMhz") == m_currentRefresh)
            chosen = m_currentRefresh;
    }
    requestMode(width, height, chosen);
}

void DisplayControl::chooseRefresh(int refreshMhz)
{
    requestMode(m_currentWidth, m_currentHeight, refreshMhz);
}

void DisplayControl::keep()
{
    m_backend->keep();
}

void DisplayControl::revert()
{
    m_backend->revert();
}

void DisplayControl::setUiScale(int percent)
{
    m_backend->setUiScale(percent);
}

void DisplayControl::resetSettings()
{
    m_backend->resetSettings();
}

void DisplayControl::setAcceptGraceMs(int ms)
{
    if (ms < 0 || ms == m_graceMs)
        return;
    m_graceMs = ms;
    emit acceptGraceMsChanged();
}

void DisplayControl::refresh()
{
    m_backend->refresh();
}

void DisplayControl::setCountdownTickMs(int ms)
{
    if (ms < 1 || ms == m_tickMs)
        return;
    m_tickMs = ms;
    emit countdownTickMsChanged();
}

void DisplayControl::mockReset()
{
    if (auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get()))
        mock->reset();
}

bool DisplayControl::mockUseScenario(const QString &name)
{
    auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get());
    return mock && mock->useScenario(name);
}

void DisplayControl::mockFailNext()
{
    if (auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get()))
        mock->setFailNext(true);
}

void DisplayControl::mockFailRevertNext()
{
    if (auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get()))
        mock->setFailRevertNext(true);
}

void DisplayControl::mockFailKeepNext()
{
    if (auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get()))
        mock->setFailKeepNext(true);
}

void DisplayControl::mockSetCrowded(bool crowded)
{
    if (auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get()))
        mock->setCrowded(crowded);
}

int DisplayControl::mockResetCalls() const
{
    auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get());
    return mock ? mock->resetCalls() : 0;
}

void DisplayControl::mockSimulateFallback()
{
    if (auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get())) {
        mock->simulateFallback();
        m_backend->takeFallbackNotice();
    }
}

int DisplayControl::mockRestartCount() const
{
    auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get());
    return mock ? mock->restartCount() : 0;
}

int DisplayControl::mockSetModeCalls() const
{
    auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get());
    return mock ? mock->setModeCalls() : 0;
}

void DisplayControl::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get()))
        mock->refreshDelayed(ms);
}

int DisplayControl::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockDisplayBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
