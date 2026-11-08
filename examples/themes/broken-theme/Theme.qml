// Deliberately invalid: checks that a broken theme is set aside
// without blocking the UI (back to the default theme, reason shown).
import Borne.Theme

ThemeBase {
    accent: "#00ff00"
    proprieteInexistante: 42
}
