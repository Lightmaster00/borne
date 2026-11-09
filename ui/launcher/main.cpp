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
#include <QQmlContext>
#include <QTimer>
#include <QQmlApplicationEngine>
#include <QTranslator>
#include <QUrl>
#include <QVariantMap>

// Mouse pointer: shown while the mouse is used, hidden after a few idle seconds or as soon
// as the keyboard or a gamepad is used (the couch case). QML reads `pointer.active` to show
// hover states and on-screen back buttons only when they make sense.
class Pointer : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)

public:
    explicit Pointer(QObject *parent = nullptr) : QObject(parent)
    {
        m_idle.setSingleShot(true);
        m_idle.setInterval(4000);
        connect(&m_idle, &QTimer::timeout, this, &Pointer::hide);
        QGuiApplication::setOverrideCursor(QCursor(Qt::BlankCursor));
    }
    bool active() const { return m_active; }

    // Called from QML when a gamepad button is pressed.
    Q_INVOKABLE void hide()
    {
        m_idle.stop();
        if (!m_active)
            return;
        m_active = false;
        QGuiApplication::setOverrideCursor(QCursor(Qt::BlankCursor));
        emit activeChanged();
    }

signals:
    void activeChanged();

protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        switch (event->type()) {
        case QEvent::MouseMove:
        case QEvent::MouseButtonPress:
        case QEvent::Wheel:
            show();
            break;
        case QEvent::KeyPress:
            hide();
            break;
        default:
            break;
        }
        return QObject::eventFilter(watched, event);
    }

private:
    void show()
    {
        m_idle.start();
        if (m_active)
            return;
        m_active = true;
        QGuiApplication::restoreOverrideCursor();
        emit activeChanged();
    }
    QTimer m_idle;
    bool m_active = false;
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
    QFont base(QStringLiteral("Inter"));
    base.setHintingPreference(QFont::PreferNoHinting);
    QGuiApplication::setFont(base);

    Pointer pointer;
    app.installEventFilter(&pointer);

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("pointer"), &pointer);
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
