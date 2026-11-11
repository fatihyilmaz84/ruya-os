#pragma once

#include "DisplayBackend.h"

#include <QList>

// In-memory Devices1.Display with three screens to try the pane on (the "scenarios"; the shell
// uses the first connected output): a 55" 4K TV (the default), a 40" 1080p TV and a 32" 4K
// monitor. It follows the service's rules: SetMode checks the mode, one change at a time,
// "unchanged" for the mode in use, and Keep/Revert need a pending change. restartShell() plays the
// shell coming back: the pending change then counts as started once.
class MockDisplayBackend final : public DisplayBackend
{
    Q_OBJECT

public:
    explicit MockDisplayBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void setMode(const QString &output, uint width, uint height, uint refreshMhz) override;
    void keep() override;
    void revert() override;
    void setUiScale(int percent) override;
    void resetSettings() override;
    void takeFallbackNotice() override;
    void refreshBrightness() override;
    void setBrightness(int percent) override;
    void restartShell() override;

    // Test hooks (reached through Display.mock*).
    void reset();
    // "tv4k" | "tv1080" | "monitor" | "laptop" (the only one with a backlight, at 60 %) | "none" (nothing
    // connected); false for another name.
    bool useScenario(const QString &name);
    // The console came back from a restart a second time with the change still unconfirmed: the
    // service's guard drops the choice and the preferred mode is back.
    void simulateFallback();
    void setFailNext(bool fail) { m_failNext = fail; }
    // The next Revert (or Keep) answers "failed" and changes nothing: the service did not get to it.
    void setFailRevertNext(bool fail) { m_failRevertNext = fail; }
    void setFailKeepNext(bool fail) { m_failKeepNext = fail; }
    // SetMode, Reset answer "busy" while this is set (the service's start-limit refusal).
    void setCrowded(bool crowded) { m_crowded = crowded; }
    // The next SetBrightness answers "failed" and changes nothing.
    void setFailBrightnessNext(bool fail) { m_failBrightnessNext = fail; }
    int brightnessCalls() const { return m_brightnessCalls; }
    // The laptop's own brightness keys: the level changes and nobody is told (the shell asks again when it looks).
    void backlightKey(int percent) { if (m_backlight >= 0) m_backlight = percent; }
    int resetCalls() const { return m_resetCalls; }
    int restartCount() const { return m_restarts; }
    int setModeCalls() const { return m_setModeCalls; }
    // Replies to refresh() arrive after `ms` with the state as it was when asked; the number of
    // replies still on their way (a test plays an old reply landing after a new one).
    void refreshDelayed(int ms);
    int pendingReplies() const { return m_pending; }

private:
    struct Mode {
        uint width;
        uint height;
        uint refreshMhz;
        bool preferred;
    };
    struct Screen {
        QString id;
        QString name;
        uint widthMm;
        uint heightMm;
        QList<Mode> modes;
    };
    struct Candidate {
        uint width = 0;
        uint height = 0;
        uint refreshMhz = 0;
        uint starts = 0;
        bool valid = false;
    };

    QVariantList outputsNow() const;
    QVariantMap pendingNow() const;
    void publish();
    int defaultIndex() const;
    int currentIndex() const;

    Screen m_screen;
    // The mode kept by the owner, as an index into the screen's modes; -1: the default.
    int m_stored = -1;
    Candidate m_candidate;
    int m_uiScale = 0;
    bool m_failNext = false;
    bool m_failRevertNext = false;
    bool m_failKeepNext = false;
    bool m_crowded = false;
    // The backlight's level in percent; -1: the screen has none (a TV, a monitor).
    int m_backlight = -1;
    bool m_failBrightnessNext = false;
    int m_brightnessCalls = 0;
    int m_resetCalls = 0;
    bool m_fallback = false;
    int m_restarts = 0;
    int m_setModeCalls = 0;
    int m_pending = 0;
};
