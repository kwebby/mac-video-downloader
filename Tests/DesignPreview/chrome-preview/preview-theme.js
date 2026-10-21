(() => {
  const theme = new URLSearchParams(location.search).get("theme");
  if (["light", "dark"].includes(theme)) document.documentElement.dataset.previewTheme = theme;
})();
