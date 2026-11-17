// Borne — QML UI launcher.
// Deliberately minimal: no business logic here or in QML. The UI talks
// to the Rust core only through the local API (BORNE_API, BORNE_WS), provided by
// the core, which launches and supervises this process.
#include <QCryptographicHash>
#include <QCursor>
#include <QDir>
#include <QDirIterator>
#include <QEvent>
#include <QFile>
#include <QFont>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QLocale>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSettings>
#include <QStandardPaths>
#include <QTranslator>
#include <QUrl>
#include <QVariantMap>

#ifdef Q_OS_MACOS
#include <Carbon/Carbon.h>
#endif

// Borne is played with a gamepad or a keyboard only: the pointer stays hidden and mouse,
// wheel and touch input never reach the interface.
class NoPointer : public QObject
{
    Q_OBJECT

public:
    explicit NoPointer(QObject *parent = nullptr) : QObject(parent)
    {
        QGuiApplication::setOverrideCursor(QCursor(Qt::BlankCursor));
    }

protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        switch (event->type()) {
        case QEvent::MouseButtonPress:
        case QEvent::MouseButtonRelease:
        case QEvent::MouseButtonDblClick:
        case QEvent::MouseMove:
        case QEvent::HoverEnter:
        case QEvent::HoverMove:
        case QEvent::HoverLeave:
        case QEvent::Wheel:
        case QEvent::TouchBegin:
        case QEvent::TouchUpdate:
        case QEvent::TouchEnd:
        case QEvent::NativeGesture:
            return true;
        default:
            return QObject::eventFilter(watched, event);
        }
    }
};

// Escape while a game runs: Borne's quit question, never the emulator's own menu. The key is
// taken from every application only while `active` (a game is running); the interface then asks
// the core to pause and ask, or to resume. Linux does the same in the core (core/src/quitkey.rs);
// macOS needs the application's event loop, so it is here (a Carbon hot key: no permission asked).
class QuitKey : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(bool available READ available CONSTANT)

public:
    explicit QuitKey(QObject *parent = nullptr) : QObject(parent)
    {
#ifdef Q_OS_MACOS
        EventTypeSpec spec{kEventClassKeyboard, kEventHotKeyPressed};
        InstallApplicationEventHandler(&QuitKey::onHotKey, 1, &spec, this, nullptr);
#endif
    }
    ~QuitKey() override { setActive(false); }

    bool active() const { return m_active; }
    bool available() const
    {
#ifdef Q_OS_MACOS
        return true;
#else
        return false;
#endif
    }
    void setActive(bool on)
    {
        if (on == m_active)
            return;
#ifdef Q_OS_MACOS
        if (on) {
            const EventHotKeyID id{'BRNE', 1};
            if (RegisterEventHotKey(kVK_Escape, 0, id, GetApplicationEventTarget(), 0, &m_ref) != noErr)
                m_ref = nullptr;
        } else if (m_ref) {
            UnregisterEventHotKey(m_ref);
            m_ref = nullptr;
        }
#endif
        m_active = on;
        emit activeChanged();
    }

signals:
    void activeChanged();
    void pressed();

private:
#ifdef Q_OS_MACOS
    static OSStatus onHotKey(EventHandlerCallRef, EventRef, void *self)
    {
        QMetaObject::invokeMethod(static_cast<QuitKey *>(self), "pressed", Qt::QueuedConnection);
        return noErr;
    }
    EventHotKeyRef m_ref = nullptr;
#endif
    bool m_active = false;
};

// The interface's language, chosen in Settings → Interface ("auto": the system's), switched at
// once: the translation reloaded and every text of the page translated again.
class UiLanguage : public QObject
{
    Q_OBJECT
public:
    UiLanguage(QTranslator *t, QString dir) : m_t(t), m_dir(std::move(dir)) {}
    QQmlApplicationEngine *engine = nullptr;
    Q_INVOKABLE void set(const QString &code)
    {
        QLocale::setDefault(code == QStringLiteral("auto") || code.isEmpty() ? QLocale::system() : QLocale(code));
        QCoreApplication::removeTranslator(m_t);
        if (m_t->load(QLocale(), QStringLiteral("borne"), QStringLiteral("_"), m_dir))
            QCoreApplication::installTranslator(m_t);
        if (engine)
            engine->retranslate();
    }

private:
    QTranslator *m_t;
    QString m_dir;
};

// Qt keeps the interface's compiled QML (~/.cache/Borne/qmlcache) and trusts it while a source
// file keeps its date. Updates used to give every file the same date in every version: the old
// interface kept running over a new core. The cache is dropped whenever the interface's files
// change (a hash of their names and contents).
static void dropStaleQmlCache(const QString &ui)
{
    QCryptographicHash h(QCryptographicHash::Sha1);
    QDirIterator it(ui, {QStringLiteral("*.qml"), QStringLiteral("*.js"), QStringLiteral("*.mjs"), QStringLiteral("qmldir")},
                    QDir::Files, QDirIterator::Subdirectories);
    QStringList files;
    while (it.hasNext())
        files << it.next();
    files.sort();
    for (const QString &f : files) {
        QFile file(f);
        if (!file.open(QIODevice::ReadOnly))
            continue;
        h.addData(f.toUtf8());
        h.addData(file.readAll());
    }
    const QString stamp = QString::fromLatin1(h.result().toHex());
    QSettings settings;
    if (settings.value(QStringLiteral("ui/qmlStamp")).toString() == stamp)
        return;
    QDir(QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/qmlcache")).removeRecursively();
    settings.setValue(QStringLiteral("ui/qmlStamp"), stamp);
}

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("Borne"));
    QGuiApplication::setOrganizationName(QStringLiteral("Borne"));

#ifdef Q_OS_MACOS
    // Borne.app/Contents/MacOS/borne-ui -> Borne.app/Contents/Resources/ui
    const QString ui = QDir(QCoreApplication::applicationDirPath() + QStringLiteral("/../Resources/ui")).absolutePath();
#else
    // <package>/bin/borne-ui -> <package>/ui
    const QString ui = QDir(QCoreApplication::applicationDirPath() + QStringLiteral("/../ui")).absolutePath();
#endif

    // UI language: the system's, or BORNE_LANG (e.g. "en", "fr") to force one.
    // English is the source language; other languages come from ui/i18n/borne_<lang>.qm.
    // The one chosen in Borne (its settings, written by the page: ui/language) comes first.
    QString lang = qEnvironmentVariable("BORNE_LANG");
    if (lang.isEmpty()) {
        const QString chosen = QSettings().value(QStringLiteral("ui/language"), QStringLiteral("auto")).toString();
        if (chosen != QStringLiteral("auto"))
            lang = chosen;
    }
    if (!lang.isEmpty())
        QLocale::setDefault(QLocale(lang));
    QTranslator translator;
    if (translator.load(QLocale(), QStringLiteral("borne"), QStringLiteral("_"), ui + QStringLiteral("/i18n")))
        QCoreApplication::installTranslator(&translator);

    // Bundled fonts (SIL Open Font License, see ui/fonts/licenses): same look on every machine.
    const QDir fonts(ui + QStringLiteral("/fonts"));
    for (const QString &f : fonts.entryList({QStringLiteral("*.otf"), QStringLiteral("*.ttf")}, QDir::Files))
        QFontDatabase::addApplicationFont(fonts.filePath(f));
    QFont base(QStringLiteral("Manrope"));
    base.setHintingPreference(QFont::PreferNoHinting);
    QGuiApplication::setFont(base);

    NoPointer noPointer;
    app.installEventFilter(&noPointer);

    dropStaleQmlCache(ui);

    QQmlApplicationEngine engine;
    QuitKey quitKey;
    engine.rootContext()->setContextProperty(QStringLiteral("quitKey"), &quitKey);
    UiLanguage uiLanguage(&translator, ui + QStringLiteral("/i18n"));
    uiLanguage.engine = &engine;
    engine.rootContext()->setContextProperty(QStringLiteral("uiLanguage"), &uiLanguage);
    // QML module for the theme API: import Borne.Theme
    engine.addImportPath(ui + QStringLiteral("/imports"));
    engine.setInitialProperties({
        {QStringLiteral("apiBase"), qEnvironmentVariable("BORNE_API")},
        {QStringLiteral("wsUrl"), qEnvironmentVariable("BORNE_WS")},
        {QStringLiteral("safeMode"), qEnvironmentVariable("BORNE_SAFE_MODE") == QStringLiteral("1")},
        {QStringLiteral("uiRestarts"), qEnvironmentVariableIntValue("BORNE_UI_RESTARTS")},
        {QStringLiteral("uiRoot"), QUrl::fromLocalFile(ui).toString()},
        {QStringLiteral("qtVersion"), QString::fromLatin1(qVersion())},
    });
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(2); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(ui + QStringLiteral("/Main.qml")));
    return app.exec();
}

#include "main.moc"
