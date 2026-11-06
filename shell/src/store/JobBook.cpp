#include "JobBook.h"

#include <utility>

void JobBook::callAnswered(const QString &job, const QString &app)
{
    m_apps.insert(job, app); // progress and the result arrive as signals
    replay(job, app);
    endCall();
}

void JobBook::callEnded()
{
    endCall();
}

void JobBook::endCall()
{
    if (--m_calls == 0)
        m_early.clear();
}

void JobBook::replay(const QString &job, const QString &app)
{
    const QList<Signal> early = m_early.take(job);
    for (const Signal &e : early) {
        if (e.finished) {
            m_apps.remove(job);
            emit jobFinished(app, e.status);
        } else {
            emit jobProgress(app, int(e.percent), e.phase);
        }
    }
}

QHash<QString, QString> JobBook::lose()
{
    const QHash<QString, QString> tracked = std::exchange(m_apps, {});
    m_early.clear();
    return tracked;
}

void JobBook::forgetAll()
{
    m_apps.clear();
    m_early.clear();
}

void JobBook::onProgress(const QString &job, uint percent, const QString &phase)
{
    const Signal s{job, false, percent, phase, QString(), ++m_signals};
    if (m_lists > 0)
        m_log.append(s);
    const auto it = m_apps.constFind(job);
    if (it != m_apps.cend())
        emit jobProgress(it.value(), int(percent), phase);
    else if (m_calls > 0)
        m_early[job].append(s);
}

void JobBook::onFinished(const QString &job, const QString &status)
{
    const Signal s{job, true, 0, QString(), status, ++m_signals};
    if (m_lists > 0)
        m_log.append(s);
    const QString app = m_apps.take(job);
    if (!app.isEmpty())
        emit jobFinished(app, status);
    else if (m_calls > 0)
        m_early[job].append(s);
}

quint64 JobBook::listSent()
{
    const quint64 request = m_seq.begin();
    ++m_lists;
    m_since.insert(request, m_signals);
    return request;
}

void JobBook::endList(quint64 request)
{
    m_since.remove(request);
    if (--m_lists == 0)
        m_log.clear();
}

void JobBook::listFailed(quint64 request)
{
    // A failure is an outcome too: a reply to an older request arriving after it is stale.
    m_seq.accept(request);
    endList(request);
}

void JobBook::listAnswered(quint64 request, QList<StoreJob> jobs)
{
    const quint64 since = m_since.value(request);
    if (!m_seq.accept(request)) {
        endList(request);
        return;
    }
    // The table is a snapshot: bring it up to date with what the signals said since the request.
    for (const Signal &s : std::as_const(m_log)) {
        if (s.n <= since)
            continue;
        for (StoreJob &j : jobs) {
            if (j.id != s.job)
                continue;
            if (s.finished) {
                j.state = QStringLiteral("finished");
                j.status = s.status;
                j.phase.clear();
                if (s.status == QLatin1String("ok"))
                    j.percent = 100;
            } else if (j.state != QLatin1String("finished")) {
                j.state = QStringLiteral("running");
                j.percent = s.percent;
                j.phase = s.phase;
            }
        }
    }
    endList(request);

    // Jobs that go on are tracked from now on. A tracked job that has ended without its JobFinished
    // reaching the shell is reported now; one that was never tracked has nothing to correct.
    QList<std::pair<QString, QString>> ended; // app, status
    for (const StoreJob &j : std::as_const(jobs)) {
        if (j.state != QLatin1String("finished")) {
            m_apps.insert(j.id, j.appId);
        } else if (m_apps.remove(j.id) > 0) {
            ended.append({j.appId, j.status});
        }
    }
    emit jobsListed(jobs);
    for (const auto &e : std::as_const(ended))
        emit jobFinished(e.first, e.second);
}
