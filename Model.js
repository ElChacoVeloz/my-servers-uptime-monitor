// Pure helpers for the uptime-monitor plugin. Kept side-effect free so the
// server-list parsing/formatting can be reasoned about (and unit tested) apart
// from the QML/Process plumbing in Panel.qml.

var MAX_SERVERS = 10

function emptyServer() {
  return { name: "", ip: "" }
}

function emptyStatuses() {
  var out = []
  for (var i = 0; i < MAX_SERVERS; i++) out.push(null)
  return out
}

function emptyStrings() {
  var out = []
  for (var i = 0; i < MAX_SERVERS; i++) out.push("")
  return out
}

// Always returns exactly MAX_SERVERS entries, trimmed. Extra input entries are
// dropped; missing ones are padded with blanks, so callers never have to
// null-check `servers[i]`.
function normalizeServers(raw) {
  var list = Array.isArray(raw) ? raw : []
  var out = []
  for (var i = 0; i < MAX_SERVERS; i++) {
    var entry = list[i] || {}
    out.push({
      name: String(entry.name || "").trim(),
      ip: String(entry.ip || "").trim()
    })
  }
  return out
}

function parseServersFile(raw) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    return normalizeServers(parsed && parsed.servers)
  } catch (e) {
    return normalizeServers([])
  }
}

function serversToFileText(servers) {
  return JSON.stringify({ servers: normalizeServers(servers) }, null, 2) + "\n"
}

// A blank slot (no IP) is never monitored, per spec — a name with no IP has
// nothing to check either, so IP is the single source of truth here.
function isConfigured(server) {
  return !!(server && String(server.ip || "").trim() !== "")
}

// Falls back to the IP so a configured-but-unnamed server still has a label.
function displayName(server) {
  if (!server) return ""
  var name = String(server.name || "").trim()
  if (name !== "") return name
  return String(server.ip || "").trim()
}

function configuredIndexes(servers) {
  var out = []
  var list = Array.isArray(servers) ? servers : []
  for (var i = 0; i < list.length; i++) {
    if (isConfigured(list[i])) out.push(i)
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_SERVERS: MAX_SERVERS,
    emptyServer: emptyServer,
    emptyStatuses: emptyStatuses,
    emptyStrings: emptyStrings,
    normalizeServers: normalizeServers,
    parseServersFile: parseServersFile,
    serversToFileText: serversToFileText,
    isConfigured: isConfigured,
    displayName: displayName,
    configuredIndexes: configuredIndexes
  }
}
