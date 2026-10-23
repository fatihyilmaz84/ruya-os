#pragma once

#include <QObject>
#include <QString>

// Transport behind the Power QML singleton. The real one talks to systemd-logind, which is an
// upstream API (org.freedesktop.login1.Manager), so there is no RuyaOS contract file. Results
// arrive asynchronously through the signals.
class PowerBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    // Asks the service what is allowed; answers through capabilities().
    virtual void refresh() = 0;
    // Action names: "suspend", "restart", "poweroff". Answers through finished().
    virtual void perform(const QString &action) = 0;

signals:
    // logind's Can* answers: "yes", "no", "challenge" or "na".
    void capabilities(const QString &suspend, const QString &restart, const QString &poweroff);
    void finished(const QString &action, bool ok, const QString &error);
};
