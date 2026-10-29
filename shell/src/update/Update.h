#pragma once

#include "UpdateBackend.h"

#include <QObject>
#include <QQmlEngine>

#include <memory>

// QML face of org.ruyaos.Update1: the OS image version, the channel, an update that was found
// or is being staged, and the rollback. Backend: RUYA_SERVICES=mock|dbus like Store and
// Profiles; there is no service yet, so the default on Linux is D-Bus and nothing answers.
class Update : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // idle | checking | downloading | staged | up-to-date | failed
    Q_PROPERTY(QString state READ state NOTIFY statusChanged)
    Q_PROPERTY(QString current READ current NOTIFY statusChanged)
    Q_PROPERTY(QString available READ available NOTIFY statusChanged)
    Q_PROPERTY(QString staged READ staged NOTIFY statusChanged)
    Q_PROPERTY(QString channel READ channel NOTIFY statusChanged)
    // Unix seconds of the last finished check, 0 = never.
    Q_PROPERTY(qint64 lastCheck READ lastCheck NOTIFY statusChanged)
    Q_PROPERTY(int progress READ progress NOTIFY statusChanged)
    Q_PROPERTY(bool rollbackAvailable READ rollbackAvailable NOTIFY statusChanged)
    Q_PROPERTY(QString error READ error NOTIFY statusChanged)
    // True once the service has answered (always, for the mock).
    Q_PROPERTY(bool ready READ isReady NOTIFY statusChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Update(std::unique_ptr<UpdateBackend> backend, QObject *parent = nullptr);
    ~Update() override;

    static Update *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QString state() const { return m_status.state; }
    QString current() const { return m_status.current; }
    QString available() const { return m_status.available; }
    QString staged() const { return m_status.staged; }
    QString channel() const { return m_status.channel; }
    qint64 lastCheck() const { return m_status.lastCheck; }
    int progress() const { return m_status.progress; }
    bool rollbackAvailable() const { return m_status.rollbackAvailable; }
    QString error() const { return m_status.error; }
    bool isReady() const { return m_known; }
    bool isMock() const { return m_backend->isMock(); }

    // Results arrive with requestFinished; the state changes arrive with statusChanged.
    Q_INVOKABLE void check();
    Q_INVOKABLE void download();
    Q_INVOKABLE void rollback();
    Q_INVOKABLE void setChannel(const QString &channel);

    // Tests only, and only with the mock backend (otherwise a no-op / 0).
    Q_INVOKABLE void mockReset();
    Q_INVOKABLE void mockSetUpdateExists(bool exists);
    Q_INVOKABLE void mockSetRollbackAvailable(bool available);
    Q_INVOKABLE void mockFailNextCheck();
    Q_INVOKABLE void mockPauseDownloadAt(int percent);
    Q_INVOKABLE void mockResumeDownload();
    Q_INVOKABLE int mockRollbackCount() const;

signals:
    void statusChanged();
    // method: "check" | "download" | "rollback" | "setChannel"; status: see the XML header.
    void requestFinished(const QString &method, const QString &status);
    // The state became "staged" (from another state): a restart finishes the update.
    void stagedReady(const QString &version);

private:
    std::unique_ptr<UpdateBackend> m_backend;
    UpdateStatus m_status;
    bool m_known = false;
};
