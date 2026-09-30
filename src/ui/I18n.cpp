#include "I18n.h"
#include "Prefs.h"
#include <QQmlEngine>

I18n::I18n(Prefs *prefs, QObject *parent) : QObject(parent), m_prefs(prefs) {}

void I18n::setEngine(QQmlEngine *engine) { m_engine = engine; }

QVariantList I18n::availableLanguages() const { return {}; }

void I18n::apply() {}
