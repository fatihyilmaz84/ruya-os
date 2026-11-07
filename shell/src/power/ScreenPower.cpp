#include "ScreenPower.h"

#include <QGuiApplication>
#include <QScreen>

#include <qpa/qplatformscreen.h>

ScreenPower::ScreenPower(QObject *parent)
    : QObject(parent)
{
}

ScreenPower *ScreenPower::create(QQmlEngine *, QJSEngine *)
{
    return new ScreenPower;
}

bool ScreenPower::supported() const
{
    // The one plugin that implements the power state for the console's screen.
    return QGuiApplication::platformName() == QLatin1String("eglfs");
}

void ScreenPower::setOn(bool on)
{
    ++m_requests;
    m_on = on;
    if (supported()) {
        const auto screens = QGuiApplication::screens();
        for (QScreen *screen : screens) {
            if (QPlatformScreen *handle = screen->handle())
                handle->setPowerState(on ? QPlatformScreen::PowerStateOn : QPlatformScreen::PowerStateOff);
        }
    }
    qInfo("ruya-shell: display %s (%s)", on ? "on" : "off", supported() ? "dpms" : "black frame only");
    emit onChanged();
}
