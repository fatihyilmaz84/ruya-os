#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QVariantList>

// The game settings file (ADR-035, docs/developers/game-settings.md, api/settings/game-settings.schema.json):
// a game ships /app/share/ruya/settings.json and the console reads it as UNTRUSTED DATA. This is a pure
// function from bytes to "a model the QML can use, or one error string". A broken file never gives a
// partial model, and nothing in it is executed, fetched or rendered as markup.
//
// The model (Result::categories) is a list of { id, rows } in the fixed category order, only the
// categories that have rows. A row is a map: id, type, label, description ("" when the file has none),
// category, restart (bool), visibleWhen ({} or { id, equals }), and by type:
//   bool    default
//   enum    default, options [{ value, label }]
//   int     default, min, max, step, unit ("" when none)
//   float   default, min, max, step (the file's, else (max - min) / 100), unit
//   action  nothing more
//   info    default (the text shown until the game publishes a value)
// label, description, option labels and the info text are already in the asked language.
namespace GameSettingsSchema {

constexpr qint64 MaxFileBytes = 64 * 1024;
constexpr int MaxSettings = 200;
constexpr int MaxOptions = 32;
constexpr int MaxLabel = 40;
constexpr int MaxDescription = 160;
constexpr int MaxUnit = 16;
constexpr int MaxLanguages = 16;     // keys of one { "en": ..., "tr": ... } object

// graphics, display, controls, audio, gameplay, interface, accessibility, advanced
const QStringList &categoryOrder();

struct Result
{
    bool ok = false;
    QString error;              // one line for a developer; empty when ok
    QVariantList categories;
    int count = 0;              // rows in all categories
};

// `language` is the profile's UI language ("tr", "tr-TR", "tr_TR.UTF-8"): the exact code, then its
// first part, then "en".
Result parse(const QByteArray &bytes, const QString &language);

// A single piece of text as a label would carry it: the plain-text rule used for every string in the
// file (no control character, no line or paragraph separator, no bidirectional mark or override).
bool isPlainText(const QString &text);

} // namespace GameSettingsSchema
