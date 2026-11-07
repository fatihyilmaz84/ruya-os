#include "IdleInhibit.h"

#include <algorithm>

IdleInhibit::IdleInhibit(QObject *parent)
    : QObject(parent)
{
    bool ok = false;
    const qreal divisor = qEnvironmentVariable("RUYA_IDLE_DIVISOR").toDouble(&ok);
    if (ok && divisor >= 1 && divisor <= 3600)
        m_divisor = divisor;
}

IdleInhibit *IdleInhibit::create(QQmlEngine *, QJSEngine *)
{
    return new IdleInhibit;
}

QStringList IdleInhibit::reasons() const
{
    QStringList list = m_counts.keys();
    std::sort(list.begin(), list.end());
    return list;
}

void IdleInhibit::acquire(const QString &reason)
{
    if (reason.isEmpty())
        return;
    const bool added = !m_counts.contains(reason);
    ++m_counts[reason];
    if (added) {
        qInfo("ruya-shell: idle inhibit +%s", qPrintable(reason));
        emit reasonsChanged();
    }
}

void IdleInhibit::release(const QString &reason)
{
    auto it = m_counts.find(reason);
    if (it == m_counts.end())
        return;
    if (--it.value() > 0)
        return;
    m_counts.erase(it);
    qInfo("ruya-shell: idle inhibit -%s", qPrintable(reason));
    emit reasonsChanged();
}

void IdleInhibit::setHeld(const QString &reason, bool held)
{
    if (reason.isEmpty() || m_counts.contains(reason) == held)
        return;
    if (held) {
        acquire(reason);
    } else {
        m_counts.remove(reason);
        qInfo("ruya-shell: idle inhibit -%s", qPrintable(reason));
        emit reasonsChanged();
    }
}

void IdleInhibit::releaseAll()
{
    if (m_counts.isEmpty())
        return;
    m_counts.clear();
    emit reasonsChanged();
}
