(() => {
  "use strict";

  const ENDPOINT = "https://halle-shared-session-coordinator.gabriel-aldea.workers.dev";
  const MAX_PAYLOAD_LENGTH = 6000;
  const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const SECRET_PATTERN = /^[A-Za-z0-9_-]{43}$/;

  const decodeBase64Url = (value) => {
    if (typeof value !== "string" || value.length === 0 || value.length > MAX_PAYLOAD_LENGTH || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
    try {
      const standard = value.replaceAll("-", "+").replaceAll("_", "/");
      const binary = atob(standard + "=".repeat((4 - standard.length % 4) % 4));
      const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
      const canonical = btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
      return canonical === value ? bytes : null;
    } catch {
      return null;
    }
  };

  const parseInvitation = (encoded) => {
    const bytes = decodeBase64Url(encoded);
    if (!bytes) return null;
    try {
      const invitation = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
      const keys = Object.keys(invitation).sort().join(",");
      if (keys !== "endpoint,inviteToken,key,v,workspaceId" || invitation.v !== 1 ||
          invitation.endpoint !== ENDPOINT || !UUID_PATTERN.test(invitation.workspaceId) ||
          !SECRET_PATTERN.test(invitation.inviteToken) || !SECRET_PATTERN.test(invitation.key) ||
          !decodeBase64Url(invitation.inviteToken) || !decodeBase64Url(invitation.key) ||
          decodeBase64Url(invitation.inviteToken).length !== 32 || decodeBase64Url(invitation.key).length !== 32) return null;
      return invitation;
    } catch {
      return null;
    }
  };

  const status = document.getElementById("invite-status");
  const actions = document.getElementById("invite-actions");
  const openButton = document.getElementById("open-halle");
  const copyButton = document.getElementById("copy-invitation");
  let encoded = "";
  const refreshInvitation = () => {
    const candidate = window.location.hash.slice(1);
    const valid = parseInvitation(candidate);
    encoded = valid ? candidate : "";
    actions.hidden = !valid;
    status.textContent = valid
      ? "Invitation format checked locally. Choose when to open Hall-e or copy the link."
      : "This invitation is missing, invalid, or unsupported. Ask the person who invited you for a new invitation.";
  };
  refreshInvitation();
  window.addEventListener("hashchange", refreshInvitation);

  openButton.addEventListener("click", () => {
    if (!encoded) return;
    const payload = encodeURIComponent(encoded);
    status.textContent = "Opening Hall-e. If it does not open, copy the invitation and paste it in Settings.";
    window.location.href = `halle://pair?payload=${payload}`;
    // Scrub the address bar only after the explicit handoff attempt. The payload
    // remains in this page's memory so the user can still copy it if needed.
    window.setTimeout(() => {
      if (document.visibilityState === "visible" && window.location.hash) {
        window.history.replaceState(null, "", window.location.pathname + window.location.search);
      }
    }, 1200);
  });

  copyButton.addEventListener("click", async () => {
    if (!encoded) return;
    const shareableLink = `${window.location.origin}${window.location.pathname}#${encoded}`;
    try {
      await navigator.clipboard.writeText(shareableLink);
      status.textContent = "Invitation link copied. Share it only with the device you want to pair.";
    } catch {
      status.textContent = "Could not copy automatically. Open Hall-e and use the invitation already in this page, or enable clipboard access and try again.";
    }
  });
})();
