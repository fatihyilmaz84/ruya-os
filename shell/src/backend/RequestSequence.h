#pragma once

#include <QtGlobal>

// Replies from the D-Bus service can arrive out of order. A backend numbers each request when it
// sends it (begin) and reports a reply only if accept() says no newer one was reported already, so
// a slow answer to an old question never replaces what a newer one delivered. One sequence per
// kind of reply that replaces a model (a state and a list are two sequences). Header-only, no
// Qt object: keep one as a member of the backend base class and call it from both the D-Bus and
// the mock backend, so a test with the mock exercises the same guard.
class RequestSequence
{
public:
    // Call when the request is sent; pass the result to accept() when its reply arrives.
    quint64 begin() { return ++m_issued; }

    // True when this reply is the newest so far and should be reported; false when it is stale.
    bool accept(quint64 request)
    {
        if (request <= m_applied)
            return false;
        m_applied = request;
        return true;
    }

private:
    quint64 m_issued = 0;
    quint64 m_applied = 0;
};
