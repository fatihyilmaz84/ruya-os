#include "MockInputBackend.h"

#include <QStringList>
#include <QTimer>
#include <QVariantMap>

namespace {
// The rule of Session1 and ruya-inputd (accounts.rs valid_app_id): three dot-separated parts or
// more, each of letters, digits, '_' and '-', not starting with a digit.
bool validAppId(const QString &id)
{
    if (id.isEmpty() || id.size() > 255)
        return false;
    const QStringList parts = id.split(QLatin1Char('.'));
    if (parts.size() < 3)
        return false;
    for (const QString &p : parts) {
        if (p.isEmpty() || p.at(0).isDigit())
            return false;
        for (const QChar c : p) {
            const bool ascii = c.unicode() < 128;
            if (!ascii || !(c.isLetterOrNumber() || c == QLatin1Char('_') || c == QLatin1Char('-')))
                return false;
        }
    }
    return true;
}
} // namespace

MockInputBackend::MockInputBackend(QObject *parent)
    : InputBackend(parent)
{
}

void MockInputBackend::setRoute(const QString &route, const QString &instance, const QString &appId,
                                const QString &profile)
{
    const quint64 request = beginRoute();
    m_calls.append(QVariantMap{
        {QStringLiteral("route"), route},
        {QStringLiteral("instance"), instance},
        {QStringLiteral("appId"), appId},
        {QStringLiteral("profile"), profile},
    });
    QString status = QStringLiteral("ok");
    const bool appOk = appId.isEmpty() || validAppId(appId);
    bool shapeOk = false;
    if (route == QLatin1String("app"))
        shapeOk = !instance.isEmpty() && !appId.isEmpty() && !profile.isEmpty();
    else if (route == QLatin1String("overlay"))
        shapeOk = !profile.isEmpty() && instance.isEmpty() == appId.isEmpty();
    else if (route == QLatin1String("shell"))
        shapeOk = instance.isEmpty() && appId.isEmpty();
    else if (route == QLatin1String("locked"))
        shapeOk = instance.isEmpty() && appId.isEmpty() && profile.isEmpty();
    if (m_fail)
        status = QStringLiteral("failed");
    else if (!shapeOk || !appOk)
        status = QStringLiteral("invalid");

    if (status == QLatin1String("ok")) {
        const bool sameOwner = m_pads && !instance.isEmpty() && instance == m_instance && profile == m_profile;
        if (route == QLatin1String("app")) {
            if (!sameOwner) {
                m_pads = true;
                ++m_padGeneration;
            }
        } else if (!(route == QLatin1String("overlay") && sameOwner)) {
            m_pads = false;
        }
        m_route = route;
        m_instance = instance;
        m_profile = profile;
    }
    QTimer::singleShot(0, this, [this, request, status] { deliverRoute(request, status); });
}

void MockInputBackend::restart()
{
    m_route = QStringLiteral("shell");
    m_instance.clear();
    m_profile.clear();
    m_pads = false;
    QTimer::singleShot(0, this, [this] { emit serviceAppeared(); });
}
