const NATIVE_HOST = "com.decopin.s17o";

async function sendNativeMessage(payload) {
  return browser.runtime.sendNativeMessage(NATIVE_HOST, payload).catch((error) => {
    console.error("sendNativeMessage failed", error);
    return { ok: false, error: String(error) };
  });
}

async function currentFocusedWindowId() {
  if (!browser.windows || !browser.windows.getLastFocused) {
    return null;
  }

  try {
    const focusedWindow = await browser.windows.getLastFocused();
    return focusedWindow && typeof focusedWindow.id === "number" ? focusedWindow.id : null;
  } catch (error) {
    console.error("getLastFocused failed", error);
    return null;
  }
}

function normalizeTab(tab, focusedWindowId) {
  return {
    id: typeof tab.id === "number" ? tab.id : null,
    title: typeof tab.title === "string" ? tab.title : "",
    url: typeof tab.url === "string" ? tab.url : "",
    active: Boolean(tab.active),
    isFocusedWindow: focusedWindowId !== null && typeof tab.windowId === "number"
      ? tab.windowId === focusedWindowId
      : null
  };
}

async function publishTabCatalog(reason) {
  if (!browser.tabs || !browser.tabs.query) {
    return { ok: false, error: "tabs API unavailable" };
  }

  try {
    const [tabs, focusedWindowId] = await Promise.all([
      browser.tabs.query({}),
      currentFocusedWindowId()
    ]);
    const payload = {
      type: "tabCatalog",
      reason,
      sentAt: Date.now(),
      tabs: tabs
        .map((tab) => normalizeTab(tab, focusedWindowId))
        .filter((tab) => typeof tab.id === "number")
    };
    return await sendNativeMessage(payload);
  } catch (error) {
    console.error("publishTabCatalog failed", error);
    return { ok: false, error: String(error) };
  }
}

browser.runtime.onMessage.addListener(async (message, sender) => {
  if (!message || message.type !== "pageSnapshot") {
    return;
  }

  const tab = sender && sender.tab ? sender.tab : null;
  const focusedWindowId = await currentFocusedWindowId();
  const payload = {
    type: "pageSnapshot",
    page: message.page,
    sender: {
      tabId: tab ? tab.id : null,
      url: tab ? tab.url || null : null,
      active: tab ? Boolean(tab.active) : null,
      isFocusedWindow: focusedWindowId !== null && tab && typeof tab.windowId === "number"
        ? tab.windowId === focusedWindowId
        : null
    },
    sentAt: Date.now()
  };

  const response = await sendNativeMessage(payload);
  await publishTabCatalog("pageSnapshot");
  return response;
});

if (browser.tabs) {
  browser.tabs.onCreated.addListener(() => {
    void publishTabCatalog("tabs.onCreated");
  });
  browser.tabs.onRemoved.addListener(() => {
    void publishTabCatalog("tabs.onRemoved");
  });
  browser.tabs.onUpdated.addListener(() => {
    void publishTabCatalog("tabs.onUpdated");
  });
  browser.tabs.onActivated.addListener(() => {
    void publishTabCatalog("tabs.onActivated");
  });
}

if (browser.windows && browser.windows.onFocusChanged) {
  browser.windows.onFocusChanged.addListener(() => {
    void publishTabCatalog("windows.onFocusChanged");
  });
}

void publishTabCatalog("background-start");
