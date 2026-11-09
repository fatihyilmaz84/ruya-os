#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QVariantMap>

// Which Wayland clients may show a window, and whose they are (ADR-023, T-164). The compositor
// (compositor/Compositor.qml, Linux only) asks it for every client by the client's peer uid; the
// rules are here so they run on every host. Each profile is the Unix user "ruya-<id>" (ADR-004)
// with its own socket <socketDir>/ruya-<id> that only that user can open.
//
// verdict(): a map { accepted: bool, profile: string, reason: string }.
//   - the shell's own user (a test client, VM checks): accepted, profile "" (shown to whoever is
//     signed in, hidden while nobody is): reason "shell";
//   - the signed-in profile's user: accepted, profile = that id: reason "profile";
//   - root or an unknown uid (< 0): always refused, reason "other-user";
//   - any other user while nobody is signed in: refused, reason "nobody-signed-in";
//   - any other user while a profile is signed in (another profile): refused, "other-user".
class AppGate : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The uid this process runs as (-1 where there are no Unix users).
    Q_PROPERTY(qint64 shellUid READ shellUid CONSTANT)
    // Where the compositor keeps the per-profile sockets.
    Q_PROPERTY(QString socketDir READ socketDir CONSTANT)

public:
    explicit AppGate(QObject *parent = nullptr) : QObject(parent) {}

    static qint64 shellUid();
    static QString socketDir() { return QStringLiteral("/run/ruya-wayland"); }

    // "ruya-<id>" for a valid profile id ([A-Za-z0-9_-], at most 32), else "".
    Q_INVOKABLE static QString unixUser(const QString &profileId);
    // The uid of a Unix user name, or -1 (unknown, or no Unix users on this host).
    Q_INVOKABLE static qint64 uidOf(const QString &user);
    // activeUid: the uid of the signed-in profile's user, -1 when nobody is signed in (or the
    // user is unknown); activeProfile: its id ("" when nobody is signed in).
    Q_INVOKABLE static QVariantMap verdict(qint64 clientUid, qint64 shellUid,
                                           const QString &activeProfile, qint64 activeUid);
};
