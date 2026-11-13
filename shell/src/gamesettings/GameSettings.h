#pragma once

#include "GameSettingsSchema.h"

#include <QByteArray>
#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QStringList>
#include <QVariantMap>

// QML face of the game settings file (ADR-035, docs/developers/game-settings.md). It only READS and
// VALIDATES: parse/load turn the bytes of a game's settings.json into a read-only model, or one error
// string (GameSettingsSchema.h describes the model). Staging, the values a game publishes and the
// panel that shows them belong to the Hub's Game panel (RUY-407); the way the file and the values
// reach the shell on the console is Platform1, planned (RUY-408).
//
// Result of parse, parseBytes, load and forApp: { ok, present, error, categories, count }.
//   ok       the file was read and is valid: `categories` is the model.
//   present  the game has a settings file at all; false only when forApp finds none (no error then).
//   error    one line for a developer ("" when ok); never a partial model next to it.
//
// The mock game (off Linux, and in tests) is "org.example.Racer", Turbo Racer in the mock library: its
// file is mock-game-settings.json, its published values are mockValues(). forApp answers only for it
// while the services are mocked; on the image there is no delivery path yet, so every game is "none".
class GameSettings : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The fixed category order of the Hub: ids, not names (the panel names and translates them).
    Q_PROPERTY(QStringList categoryOrder READ categoryOrder CONSTANT)
    // The limits of the format, so tests and the panel never repeat a number.
    Q_PROPERTY(int maxFileBytes READ maxFileBytes CONSTANT)
    Q_PROPERTY(int maxSettings READ maxSettings CONSTANT)
    Q_PROPERTY(int maxOptions READ maxOptions CONSTANT)
    Q_PROPERTY(int maxLabel READ maxLabel CONSTANT)
    Q_PROPERTY(int maxDescription READ maxDescription CONSTANT)
    Q_PROPERTY(QString mockGameId READ mockGameId CONSTANT)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit GameSettings(QObject *parent = nullptr);

    static GameSettings *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QStringList categoryOrder() const { return GameSettingsSchema::categoryOrder(); }
    int maxFileBytes() const { return static_cast<int>(GameSettingsSchema::MaxFileBytes); }
    int maxSettings() const { return GameSettingsSchema::MaxSettings; }
    int maxOptions() const { return GameSettingsSchema::MaxOptions; }
    int maxLabel() const { return GameSettingsSchema::MaxLabel; }
    int maxDescription() const { return GameSettingsSchema::MaxDescription; }
    QString mockGameId() const;
    bool isMock() const { return m_mock; }

    // `language`: the profile's UI language ("en", "tr"); a missing text falls back to "en".
    Q_INVOKABLE QVariantMap parse(const QString &json, const QString &language) const;
    // The same from raw bytes (an ArrayBuffer in QML): the size limit and UTF-8 are checked on these.
    Q_INVOKABLE QVariantMap parseBytes(const QByteArray &bytes, const QString &language) const;
    // Reads a file (never more than the limit + 1 byte) and parses it.
    Q_INVOKABLE QVariantMap load(const QString &path, const QString &language) const;
    // The settings of an installed game: the mock game's file for mockGameId, else { ok: false,
    // present: false }.
    Q_INVOKABLE QVariantMap forApp(const QString &appId, const QString &language) const;
    // The values the mock game has published, { id: value } for every row that has one.
    Q_INVOKABLE QVariantMap mockValues() const;

private:
    static QVariantMap toMap(const GameSettingsSchema::Result &result, bool present = true);

    bool m_mock = true;
};
