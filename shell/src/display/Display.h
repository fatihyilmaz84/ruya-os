#pragma once

#include "DisplayBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Devices1.Display (T-198): the connected screen's modes, the safe switch
// ("Keep this resolution?") and the size of the UI. Registered as `Display`; the class is not
// called that because Xlib's `Display` typedef would clash on Linux.
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (ruya-devices) and the mock
// elsewhere, like Network and Batteries.
//
// Only the first connected output is used (several screens at once are out of scope).
//
// Changing the mode (setMode) is: the service writes the KMS config and a marker, then this
// singleton restarts the shell; the shell comes back on the new mode, `confirming` is true, and the
// owner has `confirmSeconds` to say Keep. Revert (or the countdown running out) restores the stored
// mode and restarts again.
class DisplayControl : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Display)
    QML_SINGLETON

    // Is a screen known at all (the service answered and something is connected)?
    Q_PROPERTY(bool available READ available NOTIFY outputsChanged)
    Q_PROPERTY(QString outputId READ outputId NOTIFY outputsChanged)
    Q_PROPERTY(QString outputName READ outputName NOTIFY outputsChanged)
    // Physical size of the picture in millimetres; 0 when the display does not say.
    Q_PROPERTY(int widthMm READ widthMm NOTIFY outputsChanged)
    Q_PROPERTY(int heightMm READ heightMm NOTIFY outputsChanged)
    // The distinct sizes, in the service's order (the preferred first): [{ width, height, preferred, current }].
    // `current` marks the size of the mode in use.
    Q_PROPERTY(QVariantList resolutions READ resolutions NOTIFY outputsChanged)
    Q_PROPERTY(int currentWidth READ currentWidth NOTIFY outputsChanged)
    Q_PROPERTY(int currentHeight READ currentHeight NOTIFY outputsChanged)
    Q_PROPERTY(int currentRefreshMhz READ currentRefreshMhz NOTIFY outputsChanged)
    Q_PROPERTY(int preferredWidth READ preferredWidth NOTIFY outputsChanged)
    Q_PROPERTY(int preferredHeight READ preferredHeight NOTIFY outputsChanged)

    // A change waits for the owner's decision (set by SetMode, until Keep or Revert).
    Q_PROPERTY(bool pending READ pending NOTIFY pendingChanged)
    // ... and the shell is running on it already: show "Keep this resolution?".
    Q_PROPERTY(bool confirming READ confirming NOTIFY pendingChanged)
    Q_PROPERTY(int pendingWidth READ pendingWidth NOTIFY pendingChanged)
    Q_PROPERTY(int pendingHeight READ pendingHeight NOTIFY pendingChanged)
    Q_PROPERTY(int pendingRefreshMhz READ pendingRefreshMhz NOTIFY pendingChanged)
    // The countdown of the dialog.
    Q_PROPERTY(int confirmSeconds READ confirmSeconds CONSTANT)
    // Milliseconds per countdown step (1000; tests make it short).
    Q_PROPERTY(int countdownTickMs READ countdownTickMs WRITE setCountdownTickMs NOTIFY countdownTickMsChanged)
    // Milliseconds after the dialog appears during which Accept is ignored (1000): a double press on
    // the picker's row must not keep a mode nobody has seen. Back works at once.
    Q_PROPERTY(int acceptGraceMs READ acceptGraceMs WRITE setAcceptGraceMs NOTIFY acceptGraceMsChanged)
    // The mode in use is the display's preferred one (or no mode is known).
    Q_PROPERTY(bool currentIsPreferred READ currentIsPreferred NOTIFY outputsChanged)

    // The owner's UI size in percent: 0 is Auto, else 100, 125, 150 or 200.
    Q_PROPERTY(int uiScalePercent READ uiScalePercent NOTIFY uiScaleChanged)
    // What Auto gives for this screen (from its physical size; 1 when unknown).
    Q_PROPERTY(qreal autoScale READ autoScale NOTIFY uiScaleChanged)
    // The factor `Theme.uiScale` applies to the 1080p unit: the owner's percent, else the auto scale.
    Q_PROPERTY(qreal uiScaleFactor READ uiScaleFactor NOTIFY uiScaleChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit DisplayControl(std::unique_ptr<DisplayBackend> backend, QObject *parent = nullptr);
    ~DisplayControl() override;

    static DisplayControl *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    bool available() const { return !m_outputId.isEmpty(); }
    QString outputId() const { return m_outputId; }
    QString outputName() const { return m_outputName; }
    int widthMm() const { return m_widthMm; }
    int heightMm() const { return m_heightMm; }
    QVariantList resolutions() const { return m_resolutions; }
    int currentWidth() const { return m_currentWidth; }
    int currentHeight() const { return m_currentHeight; }
    int currentRefreshMhz() const { return m_currentRefresh; }
    int preferredWidth() const { return m_preferredWidth; }
    int preferredHeight() const { return m_preferredHeight; }
    bool pending() const { return m_pendingWidth > 0; }
    bool confirming() const { return pending() && m_pendingStarts >= 1; }
    int pendingWidth() const { return m_pendingWidth; }
    int pendingHeight() const { return m_pendingHeight; }
    int pendingRefreshMhz() const { return m_pendingRefresh; }
    int confirmSeconds() const { return 15; }
    int countdownTickMs() const { return m_tickMs; }
    void setCountdownTickMs(int ms);
    int acceptGraceMs() const { return m_graceMs; }
    void setAcceptGraceMs(int ms);
    bool currentIsPreferred() const { return m_currentWidth == m_preferredWidth && m_currentHeight == m_preferredHeight; }
    int uiScalePercent() const { return m_uiScale; }
    qreal autoScale() const { return m_autoScale; }
    qreal uiScaleFactor() const { return m_uiScale == 0 ? m_autoScale : m_uiScale / 100.0; }
    bool isMock() const { return m_backend->isMock(); }

    // The refresh rates of one size, in the service's order: [{ refreshMhz, preferred, current }].
    Q_INVOKABLE QVariantList refreshRates(int width, int height) const;
    // The size the UI would get on a screen of this physical size, as a factor on the 1080p unit
    // (see 04 §2): the reference is a 55" TV at 3 m (factor 1); a nearer, smaller screen gets less,
    // never more than 1 and never less than 0.5. 1 for an unknown size.
    Q_INVOKABLE static qreal autoScaleFor(int widthMm, int heightMm);

    // Asks for a size (keeping the current refresh rate when the size has it, else the size's
    // preferred one) or a refresh rate at the current size. The answer is setModeFinished; on "ok"
    // the shell restarts.
    Q_INVOKABLE void chooseResolution(int width, int height);
    Q_INVOKABLE void chooseRefresh(int refreshMhz);
    Q_INVOKABLE void keep();
    Q_INVOKABLE void revert();
    Q_INVOKABLE void setUiScale(int percent);
    // Mode and UI size back to the defaults; the shell restarts when the mode changes.
    Q_INVOKABLE void resetSettings();
    Q_INVOKABLE void refresh();

    // Tests only, and only with the mock backend (otherwise no-ops).
    Q_INVOKABLE void mockReset();
    Q_INVOKABLE bool mockUseScenario(const QString &name);   // "tv4k" | "tv1080" | "monitor" | "none"
    Q_INVOKABLE void mockFailNext();                         // the next SetMode answers "failed"
    Q_INVOKABLE void mockFailRevertNext();                   // the next Revert answers "failed" and changes nothing
    Q_INVOKABLE void mockFailKeepNext();                     // the next Keep answers "failed" and changes nothing
    Q_INVOKABLE void mockSetCrowded(bool crowded);           // SetMode and Reset answer "busy" (start limit)
    Q_INVOKABLE int mockResetCalls() const;
    Q_INVOKABLE void mockSimulateFallback();                 // the console came back without the change
    Q_INVOKABLE int mockRestartCount() const;
    Q_INVOKABLE int mockSetModeCalls() const;
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;

signals:
    void outputsChanged();
    void pendingChanged();
    void uiScaleChanged();
    void countdownTickMsChanged();
    void acceptGraceMsChanged();
    // status: "ok" | "unchanged" | "unknown-output" | "unknown-mode" | "busy" | "failed"
    void setModeFinished(const QString &status);
    void keepFinished(const QString &status);
    void revertFinished(const QString &status);
    // status: "ok" | "unchanged" | "busy" | "failed"
    void resetFinished(const QString &status);
    // A compositor start dropped a change nobody confirmed (the screen did not answer).
    void modeReset();

private:
    void applyState(const QVariantList &outputs, const QVariantMap &pending, int uiScale);
    void requestMode(int width, int height, int refreshMhz);

    std::unique_ptr<DisplayBackend> m_backend;
    QString m_outputId;
    QString m_outputName;
    int m_widthMm = 0;
    int m_heightMm = 0;
    QVariantList m_modes;           // of the first output
    QVariantList m_resolutions;
    int m_currentWidth = 0;
    int m_currentHeight = 0;
    int m_currentRefresh = 0;
    int m_preferredWidth = 0;
    int m_preferredHeight = 0;
    int m_pendingWidth = 0;
    int m_pendingHeight = 0;
    int m_pendingRefresh = 0;
    int m_pendingStarts = 0;
    int m_uiScale = 0;
    qreal m_autoScale = 1.0;
    int m_tickMs = 1000;
    int m_graceMs = 1000;
};
