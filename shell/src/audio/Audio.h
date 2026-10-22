#pragma once

#include "AudioBackend.h"

#include <QObject>
#include <QQmlEngine>

#include <memory>

// QML face of the master volume. Only the mock backend exists so far (T-114 adds the
// D-Bus contract and backend), so RUYA_SERVICES is not consulted yet.
class Audio : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(int volume READ volume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ isMuted NOTIFY mutedChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Audio(std::unique_ptr<AudioBackend> backend, QObject *parent = nullptr);
    ~Audio() override;

    static Audio *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    int volume() const { return m_volume; }
    bool isMuted() const { return m_muted; }
    bool isMock() const { return m_backend->isMock(); }

    Q_INVOKABLE void setVolume(int volume);
    Q_INVOKABLE void stepVolume(int delta);
    Q_INVOKABLE void toggleMute();

signals:
    void volumeChanged();
    void mutedChanged();
    // The service reported a state after a command or from outside (not the initial read):
    // what the volume OSD listens to. Also fires when nothing changed (e.g. Up at 100).
    void adjusted();

private:
    std::unique_ptr<AudioBackend> m_backend;
    int m_volume = 0;
    int m_wanted = 0; // last requested level, so rapid steps accumulate before results arrive
    bool m_muted = false;
    bool m_ready = false;
};
