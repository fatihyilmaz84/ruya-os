#include "MockPowerBackend.h"

#include <QTimer>

MockPowerBackend::MockPowerBackend(QObject *parent)
    : PowerBackend(parent)
{
}

void MockPowerBackend::refresh()
{
    const QString s = m_suspend;
    const QString r = m_restart;
    const QString p = m_poweroff;
    QTimer::singleShot(0, this, [this, s, r, p] { emit capabilities(s, r, p); });
}

// Asynchronous like the real service, so QML behaves the same with either backend.
void MockPowerBackend::perform(const QString &action)
{
    QTimer::singleShot(0, this, [this, action] { emit finished(action, true, QString()); });
}

void MockPowerBackend::setCapabilities(const QString &suspend, const QString &restart, const QString &poweroff)
{
    m_suspend = suspend;
    m_restart = restart;
    m_poweroff = poweroff;
    refresh();
}
