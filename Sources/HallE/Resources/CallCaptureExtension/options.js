const input = document.querySelector("#domain");
const status = document.querySelector("#status");
const list = document.querySelector("#domains");

function normalized(value) {
  const domain = String(value).trim().replace(/^https?:\/\//, "").split("/")[0].toLowerCase();
  return domain.includes(".") && !/[\s*@]/.test(domain) ? domain : null;
}

async function render() {
  const { customDomains = [] } = await chrome.storage.local.get("customDomains");
  list.replaceChildren(...customDomains.sort().map(domain => {
    const item = document.createElement("li");
    item.textContent = domain + " ";
    const remove = document.createElement("button");
    remove.textContent = "Remove";
    remove.addEventListener("click", async () => {
      await chrome.permissions.remove({ origins: [`https://${domain}/*`] });
      await chrome.storage.local.set({ customDomains: customDomains.filter(value => value !== domain) });
      render();
    });
    item.append(remove);
    return item;
  }));
}

document.querySelector("#add").addEventListener("click", async () => {
  const domain = normalized(input.value);
  if (!domain) { status.textContent = "Enter a hostname such as call.example.com."; return; }
  const granted = await chrome.permissions.request({ origins: [`https://${domain}/*`] });
  if (!granted) { status.textContent = "Chrome permission was not granted."; return; }
  const { customDomains = [] } = await chrome.storage.local.get("customDomains");
  if (!customDomains.includes(domain)) await chrome.storage.local.set({ customDomains: [...customDomains, domain] });
  input.value = ""; status.textContent = `Approved ${domain}.`; render();
});

render();
