(function () {
  const MAX_TEXT_LENGTH = 12000;
  const MAX_HIGHLIGHTS = 24;
  const MAX_HEADINGS = 12;
  const MAX_LINKS = 40;
  const THROTTLE_MS = 1200;

  let lastSignature = "";
  let timer = null;

  function normalizeLine(value) {
    return value.replace(/\s+/g, " ").trim();
  }

  function collectVisibleLines() {
    const source = document.body ? document.body.innerText : "";
    return source
      .split(/\n+/)
      .map(normalizeLine)
      .filter(Boolean);
  }

  function collectHeadings() {
    const nodes = Array.from(document.querySelectorAll("h1, h2, h3, [role='heading']"));
    const values = [];
    for (const node of nodes) {
      const text = normalizeLine(node.textContent || "");
      if (!text || values.includes(text)) {
        continue;
      }
      values.push(text);
      if (values.length >= MAX_HEADINGS) {
        break;
      }
    }
    return values;
  }

  function collectHighlights(lines) {
    const values = [];
    for (const line of lines) {
      if (values.includes(line)) {
        continue;
      }
      values.push(line);
      if (values.length >= MAX_HIGHLIGHTS) {
        break;
      }
    }
    return values;
  }

  function collectLinks() {
    const nodes = Array.from(document.querySelectorAll("a[href]"));
    const values = [];
    const seen = new Set();
    for (const node of nodes) {
      const href = typeof node.href === "string" ? node.href.trim() : "";
      if (!href.startsWith("http://") && !href.startsWith("https://")) {
        continue;
      }
      const text = normalizeLine(node.innerText || node.textContent || "");
      if (!text) {
        continue;
      }
      const signature = `${text}\t${href}`;
      if (seen.has(signature)) {
        continue;
      }
      seen.add(signature);
      values.push({ text, href });
      if (values.length >= MAX_LINKS) {
        break;
      }
    }
    return values;
  }

  function createSignature(page) {
    const links = (page.links || []).map((link) => `${link.text}\t${link.href}`).join("|");
    return [page.title, page.url, page.headings.join("|"), page.highlights.join("|"), links, page.visibleText]
      .join("\n")
      .slice(0, 4000);
  }

  function snapshot() {
    const lines = collectVisibleLines();
    const headings = collectHeadings();
    const highlights = collectHighlights(lines);
    const links = collectLinks();
    const page = {
      title: document.title || "",
      url: location.href,
      headings,
      highlights,
      links,
      visibleText: lines.join("\n").slice(0, MAX_TEXT_LENGTH),
      visibilityState: document.visibilityState || null
    };
    const signature = createSignature(page);
    if (signature === lastSignature) {
      return;
    }
    lastSignature = signature;
    browser.runtime.sendMessage({ type: "pageSnapshot", page }).catch((error) => {
      console.error("snapshot send failed", error);
    });
  }

  function scheduleSnapshot() {
    if (timer !== null) {
      return;
    }
    timer = window.setTimeout(() => {
      timer = null;
      snapshot();
    }, THROTTLE_MS);
  }

  snapshot();

  const observer = new MutationObserver(() => {
    scheduleSnapshot();
  });

  if (document.documentElement) {
    observer.observe(document.documentElement, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: false
    });
  }

  window.addEventListener("load", scheduleSnapshot, { once: true });
  document.addEventListener("visibilitychange", scheduleSnapshot);
})();
