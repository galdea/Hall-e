// Hall-e's extension deliberately watches URL transitions only for the listed
// provider/custom domains. It never reads page content, streams audio, or makes
// a network request. Chrome sends this message to the local native host over
// stdio; the host atomically queues it for Hall-e to validate and display.
const HOST = "cl.gabriel.halle.callcapture";
const staticHosts = [
  "meet.google.com", "web.whatsapp.com", "meet.jit.si", "whereby.com"
];
const matchingTabs = new Map();

function hostIsApproved(host, customDomains) {
  const h = host.toLowerCase();
  if (staticHosts.includes(h) || h.endsWith(".zoom.us") || h === "teams.microsoft.com" ||
      h.endsWith(".teams.microsoft.com") || h.endsWith(".jitsi.org") || h.endsWith(".whereby.com")) return true;
  return customDomains.some(domain => h === domain || h.endsWith(`.${domain}`));
}

async function customDomains() {
  const { customDomains = [] } = await chrome.storage.local.get("customDomains");
  return customDomains.map(value => String(value).replace(/^https?:\/\//, "").split("/")[0].toLowerCase()).filter(Boolean);
}

async function emit(type, tabId, url, title) {
  try {
    await chrome.runtime.sendNativeMessage(HOST, {
      version: 1, type, tabId, url, title: title || null, detectedAt: Date.now()
    });
  } catch (_) {
    // The app may not be installed/running yet. Do not retry or collect data.
  }
}

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  const url = changeInfo.url || tab.url;
  if (!url) return;
  let parsed;
  try { parsed = new URL(url); } catch (_) { return; }
  if (parsed.protocol !== "https:" || !hostIsApproved(parsed.hostname, await customDomains())) return;
  const previous = matchingTabs.get(tabId);
  if (previous === url) return;
  matchingTabs.set(tabId, url);
  emit("opened", tabId, url, tab.title);
});

chrome.tabs.onRemoved.addListener(tabId => {
  const url = matchingTabs.get(tabId);
  if (!url) return;
  matchingTabs.delete(tabId);
  emit("tab-closed", tabId, url, null);
});

chrome.runtime.onMessage.addListener(message => {
  // Settings can request an exact custom-domain permission only after the user
  // explicitly added the domain in Hall-e and clicked Chrome's approval UI.
  if (message?.type === "set-custom-domains" && Array.isArray(message.domains)) {
    chrome.storage.local.set({ customDomains: message.domains });
  }
});
