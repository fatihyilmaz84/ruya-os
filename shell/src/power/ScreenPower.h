#pragma once

#include <QObject>
#include <QQmlEngine>

// Switches the display itself on and off (T-202), through the platform plugin's power state: with
// eglfs_kms that is DPMS on the connector (QEglFSKmsScreen::setPowerState). On every other
// platform (Windows host, offscreen) the call changes nothing and `supported` is false; the
// shell's black frame is what the user sees then. `on` is what was last asked for, so tests read
// it; `requests` counts the calls.
class ScreenPower : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool on READ isOn NOTIFY onChanged)
    Q_PROPERTY(bool supported READ supported CONSTANT)
    Q_PROPERTY(int requests READ requests NOTIFY onChanged)

public:
    explicit ScreenPower(QObject *parent = nullptr);

    static ScreenPower *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    bool isOn() const { return m_on; }
    bool supported() const;
    int requests() const { return m_requests; }

    Q_INVOKABLE void setOn(bool on);

signals:
    void onChanged();

private:
    bool m_on = true;
    int m_requests = 0;
};
