#include "DBusPowerBackend.h"

#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QStringList>

#include <memory>

namespace {
const QString Service = QStringLiteral("org.freedesktop.login1");
const QString Path = QStringLiteral("/org/freedesktop/login1");
const QString Interface = QStringLiteral("org.freedesktop.login1.Manager");

// Our action names -> logind method names.
QString methodFor(const QString &action)
{
    if (action == QLatin1String("suspend"))
        return QStringLiteral("Suspend");
    if (action == QLatin1String("restart"))
        return QStringLiteral("Reboot");
    if (action == QLatin1String("poweroff"))
        return QStringLiteral("PowerOff");
    return {};
}
} // namespace

DBusPowerBackend::DBusPowerBackend(QObject *parent)
    : PowerBackend(parent)
    , m_bus(QDBusConnection::systemBus())
{
}

void DBusPowerBackend::refresh()
{
    // Three Can* calls; report once all of them answered. A failed call counts as "na".
    struct Pending {
        QStringList answers{QStringLiteral("na"), QStringLiteral("na"), QStringLiteral("na")};
        int left = 3;
    };
    auto state = std::make_shared<Pending>();
    const QStringList methods{QStringLiteral("CanSuspend"), QStringLiteral("CanReboot"),
                              QStringLiteral("CanPowerOff")};
    for (int i = 0; i < methods.size(); ++i) {
        auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, methods.at(i));
        auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, state, i](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            QDBusPendingReply<QString> reply = *w;
            if (reply.isValid())
                state->answers[i] = reply.value();
            else
                qWarning("ruya-shell: login1 Can* failed: %s", qPrintable(reply.error().message()));
            if (--state->left == 0)
                emit capabilities(state->answers.at(0), state->answers.at(1), state->answers.at(2));
        });
    }
}

void DBusPowerBackend::perform(const QString &action)
{
    const QString method = methodFor(action);
    if (method.isEmpty()) {
        emit finished(action, false, QStringLiteral("unknown action"));
        return;
    }
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg << false; // interactive: never ask for authentication on a TV
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, action](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<> reply = *w;
        if (reply.isError())
            qWarning("ruya-shell: login1 %s failed: %s", qPrintable(action), qPrintable(reply.error().message()));
        emit finished(action, !reply.isError(), reply.isError() ? reply.error().message() : QString());
    });
}
