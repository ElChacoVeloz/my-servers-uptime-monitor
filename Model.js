// Pure helpers for the uptime-monitor plugin. Kept side-effect free so the
// site-list parsing/formatting can be reasoned about (and unit tested) apart
// from the QML/Process plumbing in Panel.qml.

var MAX_SITES = 5

function emptySite() {
  return { name: "", ip: "" }
}

// Always returns exactly MAX_SITES entries, trimmed. Extra input entries are
// dropped; missing ones are padded with blanks, so callers never have to
// null-check `sites[i]`.
function normalizeSites(raw) {
  var list = Array.isArray(raw) ? raw : []
  var out = []
  for (var i = 0; i < MAX_SITES; i++) {
    var entry = list[i] || {}
    out.push({
      name: String(entry.name || "").trim(),
      ip: String(entry.ip || "").trim()
    })
  }
  return out
}

function parseSitesFile(raw) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    return normalizeSites(parsed && parsed.sites)
  } catch (e) {
    return normalizeSites([])
  }
}

function sitesToFileText(sites) {
  return JSON.stringify({ sites: normalizeSites(sites) }, null, 2) + "\n"
}

// A blank slot (no IP) is never monitored, per spec — a name with no IP has
// nothing to check either, so IP is the single source of truth here.
function isConfigured(site) {
  return !!(site && String(site.ip || "").trim() !== "")
}

// Falls back to the IP so a configured-but-unnamed site still has a label.
function displayName(site) {
  if (!site) return ""
  var name = String(site.name || "").trim()
  if (name !== "") return name
  return String(site.ip || "").trim()
}

function configuredIndexes(sites) {
  var out = []
  var list = Array.isArray(sites) ? sites : []
  for (var i = 0; i < list.length; i++) {
    if (isConfigured(list[i])) out.push(i)
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_SITES: MAX_SITES,
    emptySite: emptySite,
    normalizeSites: normalizeSites,
    parseSitesFile: parseSitesFile,
    sitesToFileText: sitesToFileText,
    isConfigured: isConfigured,
    displayName: displayName,
    configuredIndexes: configuredIndexes
  }
}
