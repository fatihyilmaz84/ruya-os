#pragma once

#include <QElapsedTimer>
#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QQuickWindow>

// How long opening a page takes (T-349): one log line per page open,
//   ruya-shell: page-open <key> create=<ms> firstSwap=<ms> afterAnim=<ms> frames=<n> maxFrame=<ms>
// all in milliseconds from begin() (the key press that opens the page): `create` when the page
// object exists (Shell.openPage), `firstSwap` the first frame shown after that, `afterAnim` when the
// page's slide and fade have ended (settled()), `frames` the frames shown from begin() to then and
// `maxFrame` the longest gap between two of them (begin() counts as the first). The line is written
// once the page has settled and a frame has been shown, whichever is later; a page that closes or is
// replaced before that writes nothing. Cheap enough to be always on: a timer and one connection.
// The frame times are taken when the GUI thread sees frameSwapped (queued from the render thread).
class PageProbe : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QQuickWindow *window READ window WRITE setWindow NOTIFY windowChanged)
    // The key begin() was called with until the line is written or the probe is cancelled, else "".
    Q_PROPERTY(QString pendingKey READ pendingKey NOTIFY stateChanged)
    // begin() was called and the page does not exist yet (openSection begins before closing pages).
    Q_PROPERTY(bool waiting READ waiting NOTIFY stateChanged)
    // The last line written, and how many were written (the tests read these).
    Q_PROPERTY(QString lastLine READ lastLine NOTIFY stateChanged)
    Q_PROPERTY(int lineCount READ lineCount NOTIFY stateChanged)

public:
    explicit PageProbe(QObject *parent = nullptr);

    QQuickWindow *window() const { return m_window; }
    void setWindow(QQuickWindow *window);
    QString pendingKey() const { return m_key; }
    bool waiting() const { return !m_key.isEmpty() && m_create < 0; }
    QString lastLine() const { return m_lastLine; }
    int lineCount() const { return m_lineCount; }

    // A page is about to open (a key press): the clock starts. A second begin() restarts it.
    Q_INVOKABLE void begin(const QString &key);
    // The page object of `key` exists.
    Q_INVOKABLE void created(const QString &key);
    // The page of `key` has finished its slide and fade.
    Q_INVOKABLE void settled(const QString &key);
    // The open did not happen (or the page went away first): nothing is written.
    Q_INVOKABLE void cancel();

signals:
    void windowChanged();
    void stateChanged();

private:
    void onFrameSwapped();
    void finishIfDone();
    void connectSwap();
    void disconnectSwap();
    qint64 now() const { return m_clock.elapsed(); }

    QPointer<QQuickWindow> m_window;
    QMetaObject::Connection m_swapConnection;
    QElapsedTimer m_clock;
    QString m_key;
    qint64 m_create = -1;
    qint64 m_firstSwap = -1;
    qint64 m_afterAnim = -1;
    qint64 m_lastFrame = 0;
    qint64 m_maxFrame = 0;
    int m_frames = 0;
    QString m_lastLine;
    int m_lineCount = 0;
};
