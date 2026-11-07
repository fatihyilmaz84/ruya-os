#pragma once

#include "RequestSequence.h"

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

// Transport behind the Display QML singleton: org.ruyaos.Devices1.Display over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. Results arrive asynchronously through
// signals.
//
// The state is one snapshot, three things the service answers separately:
//   outputs  [{ id, name, widthMm, heightMm, modes: [{ width, height, refreshMhz, preferred, current }] }]
//   pending  {} when nothing waits, else { output, width, height, refreshMhz, starts }
//   uiScale  0 (Auto), 100, 125, 150 or 200
class DisplayBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0;                        // reports the state
    virtual void setMode(const QString &output, uint width, uint height, uint refreshMhz) = 0;
    virtual void keep() = 0;
    virtual void revert() = 0;
    virtual void setUiScale(int percent) = 0;
    virtual void takeFallbackNotice() = 0;
    // Makes the compositor start again so that a written mode takes effect. The real backend ends
    // the process (the compositor unit has Restart=always); the mock only counts.
    virtual void restartShell() = 0;

signals:
    void stateChanged(const QVariantList &outputs, const QVariantMap &pending, int uiScale);
    // status: "ok" | "unchanged" | "unknown-output" | "unknown-mode" | "busy" | "no-pending" |
    // "invalid" | "failed" (see the XML header)
    void setModeFinished(const QString &status);
    void keepFinished(const QString &status);
    void revertFinished(const QString &status);
    void setUiScaleFinished(const QString &status);
    void fallbackNoticeReported(bool happened);

protected:
    // A reply to an older refresh must never replace a newer snapshot (RequestSequence).
    quint64 beginStateRequest() { return m_stateSeq.begin(); }
    bool acceptState(quint64 request) { return m_stateSeq.accept(request); }
    void deliverState(quint64 request, const QVariantList &outputs, const QVariantMap &pending, int uiScale)
    {
        if (acceptState(request))
            emit stateChanged(outputs, pending, uiScale);
    }

private:
    RequestSequence m_stateSeq;
};
