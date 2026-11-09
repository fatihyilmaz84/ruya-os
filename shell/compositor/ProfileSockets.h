#pragma once

#include <QtQml/qqml.h>
#include <QHash>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QStringList>
#include <QtWaylandCompositor/QWaylandCompositor>

// One Wayland socket per profile user (ADR-023, T-164). The compositor runs as ruya-shell, whose
// own socket (ruya-0 in its 0700 runtime directory) no profile user can reach. For each profile
// user this makes a listening socket <directory>/<user> (directory: the unit's RuntimeDirectory
// /run/ruya-wayland, 0711, so it can be passed but not listed), mode 0600 with one ACL entry
// user:<user>:rw-: only that user (and ruya-shell) can connect. It is bound in a private 0700
// staging directory, given its mode and ACL there and only then renamed into place, so there is
// no moment in which another user could connect. The fd goes to QWaylandCompositor::
// addSocketDescriptor; libwayland cannot remove a listening socket again, so a socket of a
// profile that is gone is unlinked (nobody can connect to it any more) and its fd stays idle.
//
// Which profile a client belongs to is decided per client by its peer uid (AppGate.verdict, in
// Compositor.qml); the socket only keeps every other user out.
class ProfileSockets : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QWaylandCompositor *compositor READ compositor WRITE setCompositor NOTIFY compositorChanged)
    Q_PROPERTY(QString directory READ directory WRITE setDirectory NOTIFY directoryChanged)

public:
    explicit ProfileSockets(QObject *parent = nullptr);

    QWaylandCompositor *compositor() const { return m_compositor; }
    void setCompositor(QWaylandCompositor *compositor);
    QString directory() const { return m_directory; }
    void setDirectory(const QString &directory);

    // Makes sure each user in `users` ("ruya-<id>") has a socket, and unlinks the sockets of
    // users no longer listed. Returns the users that have a socket now.
    Q_INVOKABLE QStringList sync(const QStringList &users);
    // The socket path of a user that has one, else "".
    Q_INVOKABLE QString pathOf(const QString &user) const;

signals:
    void compositorChanged();
    void directoryChanged();

private:
    bool open(const QString &user);

    QPointer<QWaylandCompositor> m_compositor;
    QString m_directory = QStringLiteral("/run/ruya-wayland");
    QHash<QString, QString> m_paths;   // user -> socket path
};
