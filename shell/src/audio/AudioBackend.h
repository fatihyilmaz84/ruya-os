#pragma once

#include <QObject>

// Transport behind the Audio QML singleton. Only a mock exists so far; a D-Bus backend
// follows the audio contract (T-114). Results arrive asynchronously through stateChanged,
// which is emitted after every command, even when the state did not change (the volume
// OSD still shows when the user presses Volume Up at 100).
class AudioBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0;
    virtual void setVolume(int volume) = 0; // 0-100, clamped by the backend
    virtual void setMuted(bool muted) = 0;

signals:
    void stateChanged(int volume, bool muted);
};
