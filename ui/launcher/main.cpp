// Borne — QML UI launcher.
// Deliberately minimal: no business logic here or in QML. The UI talks
// to the Rust core only through the local API (BORNE_API, BORNE_WS), provided by
// the core, which launches and supervises this process.
#include <QCursor>
#include <QDir>
#include <QEvent>
#include <QFont>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QLocale>
#include <QQmlApplicationEngine>
#include <QTranslator>
#include <QUrl>
#include <QVariantMap>

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
    const QString lang = qEnvironmentVariable("BORNE_LANG");
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

    QQmlApplicationEngine engine;
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
