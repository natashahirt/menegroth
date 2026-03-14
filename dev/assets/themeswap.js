// Custom themeswap: default to documenter-light regardless of OS preference.
// User can still manually select a different theme via Settings.
// Also inverts logo (white) in dark themes.
var DARK_THEMES = [
  "documenter-dark",
  "catppuccin-frappe",
  "catppuccin-macchiato",
  "catppuccin-mocha",
];
var _activeTheme = null;

function set_logo_for_theme(activeTheme) {
  var imgs = document.querySelectorAll(".docs-logo img");
  var isDark = activeTheme && DARK_THEMES.indexOf(activeTheme) >= 0;
  for (var j = 0; j < imgs.length; j++) {
    imgs[j].style.filter = isDark ? "invert(1)" : "";
  }
}

function set_theme_from_local_storage() {
  var theme = null;
  if (window.localStorage != null) {
    theme = window.localStorage.getItem("documenter-theme");
  }
  var active = null;
  var primaryLightTheme = null;
  var primaryDarkTheme = null;
  for (var i = 0; i < document.styleSheets.length; i++) {
    var ss = document.styleSheets[i];
    var themename = ss.ownerNode.getAttribute("data-theme-name");
    if (themename === null) continue;
    if (ss.ownerNode.getAttribute("data-theme-primary") !== null) {
      primaryLightTheme = themename;
    }
    if (ss.ownerNode.getAttribute("data-theme-primary-dark") !== null) {
      primaryDarkTheme = themename;
    }
    if (themename === theme) active = i;
  }
  var activeTheme = null;
  if (active !== null) {
    document.getElementsByTagName("html")[0].className = "theme--" + theme;
    activeTheme = theme;
  } else {
    // Always use light theme as default (ignore OS prefers-color-scheme)
    activeTheme = primaryLightTheme;
    if (activeTheme === null) {
      console.error("Unable to determine primary theme.");
      return;
    }
    document.getElementsByTagName("html")[0].className = "";
  }
  for (var i = 0; i < document.styleSheets.length; i++) {
    var ss = document.styleSheets[i];
    var themename = ss.ownerNode.getAttribute("data-theme-name");
    if (themename === null) continue;
    ss.disabled = !(themename == activeTheme);
  }
  _activeTheme = activeTheme;
  set_logo_for_theme(activeTheme);
}
set_theme_from_local_storage();
document.addEventListener("DOMContentLoaded", function () {
  set_logo_for_theme(_activeTheme);
});
