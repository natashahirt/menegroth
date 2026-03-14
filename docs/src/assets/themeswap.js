// Custom themeswap: default to documenter-light regardless of OS preference.
// User can still manually select a different theme via Settings.
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
}
set_theme_from_local_storage();
