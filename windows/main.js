const { app, BrowserWindow, ipcMain, Notification } = require('electron');
const fs = require('fs');
const path = require('path');

const APP_NAME = 's17o';
const DODGERS_BLUE = '#0057B8';
const COOLDOWN_MS = 45_000;
const MONITOR_INTERVAL_MS = 1_200;
const DEFAULT_KEYWORDS = 'Ohtani\nShohei Ohtani';
const DEFAULT_SETTINGS = {
  keywordsText: DEFAULT_KEYWORDS,
  automationURLText: 'https://www.mlb.com/dodgers/schedule/',
  automationStartAt: '',
  autoOpenTargetPage: false,
  autoStartMonitoringAtSchedule: false,
  autoPageAudioControl: false,
};

let controlWindow = null;
let monitoredWindow = null;
let monitorTimer = null;
let automationTimer = null;
let lastAutomationFireAt = null;
let lastDomNotificationSignature = '';
let lastNotificationAt = new Map();
let calendarResolution = null;
let lastAcceptedSnapshot = null;
let pageAudioBaselineMuted = null;
let pageAudioManagedMuted = null;

const runtime = {
  isRunning: false,
  statusMessage: '停止中',
  automationStatus: '自動化オフ',
  calendarStatus: '未使用',
  soundStatus: '手動',
  monitoredPageTitle: '',
  monitoredPageURL: '',
  pageSummary: 'まだありません',
  baseballSummary: '未検出',
  lastMatch: 'まだありません',
  lastError: '',
};

let settings = null;

function settingsPath() {
  return path.join(app.getPath('userData'), 'settings.json');
}

function loadSettings() {
  try {
    const raw = fs.readFileSync(settingsPath(), 'utf8');
    const parsed = JSON.parse(raw);
    return { ...DEFAULT_SETTINGS, ...parsed };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

function saveSettings() {
  fs.mkdirSync(path.dirname(settingsPath()), { recursive: true });
  fs.writeFileSync(settingsPath(), JSON.stringify(settings, null, 2));
}

function publicState() {
  return {
    settings,
    runtime,
    monitoredPageTitle: runtime.monitoredPageTitle,
    monitoredPageURL: runtime.monitoredPageURL,
  };
}

function pushState() {
  if (controlWindow && !controlWindow.isDestroyed()) {
    controlWindow.webContents.send('state:changed', publicState());
  }
}

function setRuntime(partial) {
  Object.assign(runtime, partial);
  pushState();
}

function clearError() {
  setRuntime({ lastError: '' });
}

function surfaceError(message) {
  setRuntime({ lastError: message });
}

function parsedKeywords() {
  return settings.keywordsText
    .split(/\r?\n/)
    .map((value) => value.trim())
    .filter(Boolean);
}

function normalize(text) {
  return String(text || '')
    .normalize('NFKD')
    .toLowerCase()
    .replace(/[^a-z0-9 ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function originalCase(text) {
  return String(text || '').replace(/\s+/g, ' ').trim();
}

function normalizedURL(url) {
  try {
    const parsed = new URL(url);
    parsed.hash = '';
    const value = parsed.toString();
    return value.endsWith('/') ? value.slice(0, -1) : value;
  } catch {
    return String(url || '');
  }
}

function validatedAutomationSourceURL() {
  const trimmed = settings.automationURLText.trim();
  if (!trimmed) {
    throw new Error('自動オープン用の URL が未設定です。');
  }
  const url = new URL(trimmed);
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error('自動オープン用の URL は http または https にしてください。');
  }
  return url;
}

function isCalendarURL(url) {
  return url.host.toLowerCase().includes('mlb.com') && url.pathname.toLowerCase().includes('/schedule');
}

function urlsMatch(lhs, rhs) {
  if (!lhs || !rhs) {
    return false;
  }
  return normalizedURL(lhs) === normalizedURL(rhs);
}

function monthNumber(name) {
  switch (name.toLowerCase()) {
    case 'jan':
    case 'january': return 1;
    case 'feb':
    case 'february': return 2;
    case 'mar':
    case 'march': return 3;
    case 'apr':
    case 'april': return 4;
    case 'may': return 5;
    case 'jun':
    case 'june': return 6;
    case 'jul':
    case 'july': return 7;
    case 'aug':
    case 'august': return 8;
    case 'sep':
    case 'sept':
    case 'september': return 9;
    case 'oct':
    case 'october': return 10;
    case 'nov':
    case 'november': return 11;
    case 'dec':
    case 'december': return 12;
    default: return null;
  }
}

function resolvedTimeZone(abbreviation) {
  switch ((abbreviation || '').toUpperCase()) {
    case 'ET':
    case 'EDT':
    case 'EST': return 'America/New_York';
    case 'CT':
    case 'CDT':
    case 'CST': return 'America/Chicago';
    case 'MT':
    case 'MDT':
    case 'MST': return 'America/Denver';
    case 'PT':
    case 'PDT':
    case 'PST': return 'America/Los_Angeles';
    case 'JST': return 'Asia/Tokyo';
    default: return null;
  }
}

function extractMonthDay(texts) {
  const monthRegex = /\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+(\d{1,2})\b/i;
  const numericRegex = /\b(\d{1,2})\/(\d{1,2})\b/;

  for (const text of texts) {
    const monthMatch = text.match(monthRegex);
    if (monthMatch) {
      const month = monthNumber(monthMatch[1]);
      const day = Number(monthMatch[2]);
      if (month && day) {
        return { month, day };
      }
    }
    const numericMatch = text.match(numericRegex);
    if (numericMatch) {
      return { month: Number(numericMatch[1]), day: Number(numericMatch[2]) };
    }
  }

  return null;
}

function extractTimeMatches(texts) {
  const regex = /\b(\d{1,2}):(\d{2})\s*([AaPp][Mm])(?:\s*(ET|EDT|EST|CT|CDT|CST|MT|MDT|MST|PT|PDT|PST|JST))?\b/g;
  const seen = new Set();
  const matches = [];

  for (const text of texts) {
    for (const match of text.matchAll(regex)) {
      const label = originalCase(match[0]);
      if (seen.has(label)) {
        continue;
      }
      seen.add(label);
      matches.push({
        label,
        hour: Number(match[1]),
        minute: Number(match[2]),
        meridiem: match[3].toUpperCase(),
        timeZoneAbbreviation: match[4] ? match[4].toUpperCase() : null,
      });
    }
  }

  return matches;
}

function buildDate(monthDay, timeMatch, referenceDate) {
  if (!timeMatch) {
    return null;
  }
  let hour = timeMatch.hour % 12;
  if (timeMatch.meridiem === 'PM') {
    hour += 12;
  }

  const reference = new Date(referenceDate);
  const year = reference.getFullYear();
  const month = monthDay ? monthDay.month : reference.getMonth() + 1;
  const day = monthDay ? monthDay.day : reference.getDate();
  const zone = resolvedTimeZone(timeMatch.timeZoneAbbreviation);

  if (zone) {
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: zone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false,
    });
    const parts = formatter.formatToParts(reference);
    const partMap = Object.fromEntries(parts.filter((part) => part.type !== 'literal').map((part) => [part.type, part.value]));
    const zonedYear = monthDay ? year : Number(partMap.year);
    const zonedMonth = monthDay ? month : Number(partMap.month);
    const zonedDay = monthDay ? day : Number(partMap.day);
    return new Date(Date.UTC(zonedYear, zonedMonth - 1, zonedDay, hour, timeMatch.minute, 0));
  }

  return new Date(year, month - 1, day, hour, timeMatch.minute, 0);
}

function resolveCalendar(snapshot, referenceDate) {
  const sourceURL = new URL(snapshot.url);
  if (!isCalendarURL(sourceURL)) {
    throw new Error('MLBカレンダーページではありません。');
  }

  const candidates = [];
  const seen = new Set();
  for (const link of snapshot.links || []) {
    let target;
    try {
      target = new URL(link.href);
    } catch {
      continue;
    }
    if (!target.host.toLowerCase().includes('mlb.com')) {
      continue;
    }
    if (isCalendarURL(target)) {
      continue;
    }
    const path = target.pathname.toLowerCase();
    const text = normalize(link.text);
    const preferred = text.includes('watch') || text.includes('video') || text.includes('live') || path.includes('/video/') || path.includes('/live');
    const isGameLink = preferred || text.includes('gameday') || path.includes('gameday') || path.includes('/game/');
    if (!isGameLink) {
      continue;
    }
    const key = normalizedURL(target);
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    candidates.push({ url: target, label: originalCase(link.text), preferred });
  }

  if (candidates.length === 0) {
    throw new Error('カレンダーページから試合リンクを抽出できませんでした。');
  }

  const preferred = candidates.filter((candidate) => candidate.preferred);
  const selectedPool = preferred.length === 1 ? preferred : candidates;
  if (selectedPool.length !== 1) {
    throw new Error(`カレンダーページに試合候補が ${selectedPool.length} 件あります。対象試合だけが見える状態にしてください。`);
  }

  const selected = selectedPool[0];
  const texts = [snapshot.title, ...(snapshot.headings || []), ...(snapshot.highlights || []), ...String(snapshot.visibleText || '').split(/\n+/)];
  const monthDay = extractMonthDay(texts);
  const timeMatches = extractTimeMatches(texts);
  const timeMatch = timeMatches.length === 1 ? timeMatches[0] : null;
  const startDate = buildDate(monthDay, timeMatch, referenceDate);

  return {
    sourceURL: sourceURL.toString(),
    targetURL: selected.url.toString(),
    startDate: startDate ? startDate.toISOString() : null,
    targetLabel: selected.label || selected.url.toString(),
    timeLabel: timeMatch ? timeMatch.label : null,
    summary: timeMatch ? `${selected.label || selected.url.toString()} / ${timeMatch.label}` : (selected.label || selected.url.toString()),
  };
}

function extractNamedField(labels, lines) {
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    for (const label of labels) {
      const position = line.indexOf(label);
      if (position < 0) {
        continue;
      }
      const suffix = originalCase(line.slice(position + label.length).replace(/^[\s:\-]+/, ''));
      if (suffix) {
        return suffix;
      }
      const nextLine = originalCase(lines[index + 1] || '');
      if (nextLine) {
        return nextLine;
      }
    }
  }
  return null;
}

function extractBaseballContext(lines) {
  const context = {
    inningHalf: null,
    currentBatter: null,
    previousBatter: null,
    onDeck: null,
    pitcher: null,
    outs: null,
  };

  const inningLine = lines.find((line) => /\b(top|bottom)\s+\d{1,2}(st|nd|rd|th)?\b/.test(line));
  if (inningLine) {
    context.inningHalf = originalCase(inningLine);
  }

  const outsLine = lines.find((line) => line.includes('outs'));
  if (outsLine) {
    context.outs = originalCase(outsLine);
  }

  context.currentBatter = extractNamedField(['batter', 'current batter', 'at bat', 'now batting'], lines);
  context.previousBatter = extractNamedField(['previous batter', 'last batter'], lines);
  context.onDeck = extractNamedField(['on deck', 'next batter'], lines);
  context.pitcher = extractNamedField(['pitcher', 'pitching'], lines);

  const parts = [];
  if (context.inningHalf) parts.push(`回: ${context.inningHalf}`);
  if (context.currentBatter) parts.push(`打者: ${context.currentBatter}`);
  if (context.previousBatter) parts.push(`前打者: ${context.previousBatter}`);
  if (context.onDeck) parts.push(`次打者: ${context.onDeck}`);
  if (context.pitcher) parts.push(`投手: ${context.pitcher}`);
  if (context.outs) parts.push(`アウト: ${context.outs}`);
  context.summary = parts.join(' / ');
  return context;
}

function classifySnapshot(snapshot, keywords) {
  const lines = String(snapshot.visibleText || '')
    .split(/\n+/)
    .map(normalize)
    .filter(Boolean);
  const signals = [...(snapshot.headings || []), ...(snapshot.highlights || [])].map(normalize);
  const normalizedURLValue = normalize(snapshot.url);
  const normalizedTitle = normalize(snapshot.title);
  let baseballScore = 0;
  for (const token of ['inning', 'innings', 'top', 'bottom', 'outs', 'pitcher', 'batter', 'at bat', 'on deck', 'play by play', 'box score', 'home run', 'strikeout']) {
    if (normalizedTitle.includes(token) || normalizedURLValue.includes(token)) {
      baseballScore += 2;
    }
    if (signals.some((value) => value.includes(token)) || lines.some((value) => value.includes(token))) {
      baseballScore += 1;
    }
  }
  if (normalizedURLValue.includes('mlb') || normalizedURLValue.includes('gameday') || normalizedURLValue.includes('baseball')) {
    baseballScore += 2;
  }

  const mode = baseballScore >= 4 ? '野球' : '汎用';
  const baseballContext = mode === '野球' ? extractBaseballContext(lines) : null;
  const joinedHighlights = normalize((snapshot.highlights || []).join('\n'));
  const signature = [snapshot.url, snapshot.title, baseballContext ? baseballContext.summary : joinedHighlights].join('\n');
  const normalizedKeywords = keywords.map((keyword) => ({ raw: keyword, normalized: normalize(keyword) }));

  let domMatch = null;
  if (baseballContext) {
    for (const [label, value] of [['現在打者', baseballContext.currentBatter], ['前打者', baseballContext.previousBatter], ['次打者', baseballContext.onDeck], ['投手', baseballContext.pitcher]]) {
      if (!value) {
        continue;
      }
      const normalizedValue = normalize(value);
      const matched = normalizedKeywords.find((keyword) => normalizedValue.includes(keyword.normalized));
      if (matched) {
        domMatch = {
          keyword: matched.raw,
          details: `${label}で ${matched.raw} を検出しました: ${value}${baseballContext.summary ? ` (${baseballContext.summary})` : ''}`,
          signature,
        };
        break;
      }
    }
  }

  if (!domMatch) {
    const searchable = normalize([snapshot.title, joinedHighlights, String(snapshot.visibleText || '').slice(0, 2000)].join('\n'));
    const matched = normalizedKeywords.find((keyword) => searchable.includes(keyword.normalized));
    if (matched) {
      domMatch = {
        keyword: matched.raw,
        details: `ページ表示から ${matched.raw} を検出しました: ${snapshot.title}`,
        signature,
      };
    }
  }

  const summary = baseballContext && baseballContext.summary
    ? baseballContext.summary
    : ((snapshot.headings && snapshot.headings[0]) || (snapshot.highlights && snapshot.highlights[0]) || snapshot.title || 'まだありません');

  return { mode, baseballContext, domMatch, summary };
}

function shouldEnablePageAudio(baseballContext, keywords) {
  if (!baseballContext) {
    return false;
  }
  const activeFields = [baseballContext.currentBatter, baseballContext.onDeck, baseballContext.pitcher].filter(Boolean);
  const normalizedKeywords = keywords.map(normalize);
  return activeFields.some((field) => {
    const normalizedField = normalize(field);
    return normalizedKeywords.some((keyword) => normalizedField.includes(keyword));
  });
}

async function setPageAudioMuted(targetMuted) {
  if (!monitoredWindow || monitoredWindow.isDestroyed()) {
    return;
  }
  const currentMuted = monitoredWindow.webContents.isAudioMuted();
  if (pageAudioBaselineMuted === null) {
    pageAudioBaselineMuted = currentMuted;
  }
  if (pageAudioManagedMuted === targetMuted) {
    return;
  }
  monitoredWindow.webContents.setAudioMuted(targetMuted);
  pageAudioManagedMuted = targetMuted;
  setRuntime({ soundStatus: targetMuted ? 'ページ自動ミュート' : 'ページ自動ON' });
}

function restorePageAudioIfNeeded() {
  if (!monitoredWindow || monitoredWindow.isDestroyed()) {
    pageAudioBaselineMuted = null;
    pageAudioManagedMuted = null;
    return;
  }
  if (pageAudioBaselineMuted !== null) {
    monitoredWindow.webContents.setAudioMuted(pageAudioBaselineMuted);
  }
  pageAudioBaselineMuted = null;
  pageAudioManagedMuted = null;
  setRuntime({ soundStatus: '手動' });
}

function maybeNotifyDomMatch(domMatch) {
  if (!domMatch || !runtime.isRunning) {
    return;
  }
  if (domMatch.signature === lastDomNotificationSignature) {
    return;
  }
  const now = Date.now();
  const key = `dom:${normalize(domMatch.keyword)}`;
  const previous = lastNotificationAt.get(key) || 0;
  if (now - previous < COOLDOWN_MS) {
    return;
  }
  lastDomNotificationSignature = domMatch.signature;
  lastNotificationAt.set(key, now);
  setRuntime({ lastMatch: domMatch.details, statusMessage: 'DOM 一致を検出しました' });
  if (Notification.isSupported()) {
    new Notification({ title: APP_NAME, body: domMatch.details }).show();
  }
}

function snapshotScript() {
  return `(() => {
    const normalizeLine = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const collectVisibleLines = () => {
      const source = document.body ? document.body.innerText : '';
      return source.split(/\\n+/).map(normalizeLine).filter(Boolean);
    };
    const collectHeadings = () => {
      const nodes = Array.from(document.querySelectorAll('h1, h2, h3, [role="heading"]'));
      const values = [];
      for (const node of nodes) {
        const text = normalizeLine(node.textContent || '');
        if (!text || values.includes(text)) continue;
        values.push(text);
        if (values.length >= 12) break;
      }
      return values;
    };
    const collectHighlights = (lines) => {
      const values = [];
      for (const line of lines) {
        if (values.includes(line)) continue;
        values.push(line);
        if (values.length >= 24) break;
      }
      return values;
    };
    const collectLinks = () => {
      const nodes = Array.from(document.querySelectorAll('a[href]'));
      const seen = new Set();
      const values = [];
      for (const node of nodes) {
        const href = typeof node.href === 'string' ? node.href.trim() : '';
        if (!href.startsWith('http://') && !href.startsWith('https://')) continue;
        const text = normalizeLine(node.innerText || node.textContent || '');
        if (!text) continue;
        const signature = text + '\\t' + href;
        if (seen.has(signature)) continue;
        seen.add(signature);
        values.push({ text, href });
        if (values.length >= 40) break;
      }
      return values;
    };
    const lines = collectVisibleLines();
    return {
      title: document.title || '',
      url: location.href,
      headings: collectHeadings(),
      highlights: collectHighlights(lines),
      links: collectLinks(),
      visibleText: lines.join('\\n').slice(0, 12000),
      visibilityState: document.visibilityState || null,
      sentAt: Date.now(),
    };
  })();`;
}

async function collectSnapshot() {
  if (!monitoredWindow || monitoredWindow.isDestroyed()) {
    throw new Error('監視ページがありません。');
  }
  const snapshot = await monitoredWindow.webContents.executeJavaScript(snapshotScript(), true);
  lastAcceptedSnapshot = snapshot;
  setRuntime({
    monitoredPageTitle: snapshot.title || 'まだありません',
    monitoredPageURL: snapshot.url || '',
  });
  return snapshot;
}

function refreshCalendarStateFromSettings() {
  const trimmed = settings.automationURLText.trim();
  if (!trimmed) {
    calendarResolution = null;
    setRuntime({ calendarStatus: '未使用' });
    return;
  }
  let sourceURL;
  try {
    sourceURL = validatedAutomationSourceURL();
  } catch {
    calendarResolution = null;
    setRuntime({ calendarStatus: 'URL不正' });
    return;
  }
  if (!isCalendarURL(sourceURL)) {
    calendarResolution = null;
    setRuntime({ calendarStatus: '通常URL' });
    return;
  }
  if (calendarResolution && urlsMatch(calendarResolution.sourceURL, sourceURL.toString())) {
    setRuntime({ calendarStatus: calendarResolution.summary });
    return;
  }
  calendarResolution = null;
  setRuntime({ calendarStatus: '読取待ち' });
  if (lastAcceptedSnapshot && urlsMatch(sourceURL.toString(), lastAcceptedSnapshot.url)) {
    tryResolveCalendar(lastAcceptedSnapshot, false);
  }
}

function tryResolveCalendar(snapshot, surfacesFailure) {
  let sourceURL;
  try {
    sourceURL = validatedAutomationSourceURL();
  } catch {
    return;
  }
  if (!isCalendarURL(sourceURL)) {
    return;
  }
  if (!urlsMatch(sourceURL.toString(), snapshot.url)) {
    return;
  }
  try {
    calendarResolution = resolveCalendar(snapshot, snapshot.sentAt || Date.now());
    if (calendarResolution.startDate) {
      settings.automationStartAt = calendarResolution.startDate.slice(0, 16);
      saveSettings();
    }
    setRuntime({ calendarStatus: calendarResolution.summary });
  } catch (error) {
    calendarResolution = null;
    setRuntime({ calendarStatus: error.message });
    if (surfacesFailure) {
      surfaceError(error.message);
    }
  }
}

function resolvedAutomationTargetURL() {
  const sourceURL = validatedAutomationSourceURL();
  if (!isCalendarURL(sourceURL)) {
    return sourceURL.toString();
  }
  if (!calendarResolution || !urlsMatch(calendarResolution.sourceURL, sourceURL.toString())) {
    throw new Error('Safari ではなく Windows 版では、このアプリ内で MLB カレンダーページを開いて対象試合だけが見える状態にしてください。');
  }
  return calendarResolution.targetURL;
}

function ensureMonitoredWindow() {
  if (monitoredWindow && !monitoredWindow.isDestroyed()) {
    return monitoredWindow;
  }
  monitoredWindow = new BrowserWindow({
    width: 1280,
    height: 900,
    backgroundColor: DODGERS_BLUE,
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      autoplayPolicy: 'no-user-gesture-required',
    },
  });
  monitoredWindow.on('closed', () => {
    monitoredWindow = null;
    if (runtime.isRunning) {
      stopMonitoring('監視ページが閉じられました。');
    }
  });
  monitoredWindow.webContents.on('did-finish-load', () => {
    void collectAndProcessSnapshot();
  });
  return monitoredWindow;
}

async function openSourcePageNow() {
  clearError();
  const sourceURL = validatedAutomationSourceURL().toString();
  const window = ensureMonitoredWindow();
  await window.loadURL(sourceURL);
  window.show();
  window.focus();
  setRuntime({ automationStatus: '対象URLを開きました' });
}

function scheduleAutomation() {
  if (automationTimer) {
    clearTimeout(automationTimer);
    automationTimer = null;
  }
  if (!settings.autoOpenTargetPage && !settings.autoStartMonitoringAtSchedule) {
    setRuntime({ automationStatus: '自動化オフ' });
    return;
  }
  if (!settings.automationStartAt) {
    setRuntime({ automationStatus: '開始時刻未設定' });
    return;
  }
  const targetTime = new Date(settings.automationStartAt);
  if (Number.isNaN(targetTime.getTime())) {
    setRuntime({ automationStatus: '開始時刻不正' });
    return;
  }
  if (lastAutomationFireAt && lastAutomationFireAt >= targetTime.getTime()) {
    setRuntime({ automationStatus: `実行済み: ${new Date(lastAutomationFireAt).toLocaleString()}` });
    return;
  }
  const delay = targetTime.getTime() - Date.now();
  if (delay <= 0) {
    setRuntime({ automationStatus: '予定時刻到達' });
    void executeScheduledAutomation('予定時刻到達');
    return;
  }
  automationTimer = setTimeout(() => {
    void executeScheduledAutomation('予定時刻到達');
  }, delay);
  setRuntime({ automationStatus: `待機中: ${targetTime.toLocaleString()}` });
}

async function executeScheduledAutomation(trigger) {
  clearError();
  try {
    if (settings.autoOpenTargetPage) {
      const targetURL = resolvedAutomationTargetURL();
      const window = ensureMonitoredWindow();
      await window.loadURL(targetURL);
      window.show();
      window.focus();
    }
    if (settings.autoStartMonitoringAtSchedule) {
      await startMonitoringInternal();
      if (!runtime.isRunning) {
        throw new Error('監視開始に失敗しました。');
      }
    }
    lastAutomationFireAt = Date.now();
    if (settings.autoOpenTargetPage && settings.autoStartMonitoringAtSchedule) {
      setRuntime({ automationStatus: `${trigger}: 対象ページを開いて監視開始` });
    } else if (settings.autoOpenTargetPage) {
      setRuntime({ automationStatus: `${trigger}: 対象ページを開きました` });
    } else {
      setRuntime({ automationStatus: `${trigger}: 監視開始` });
    }
  } catch (error) {
    surfaceError(error.message);
    setRuntime({ automationStatus: `${trigger}: 失敗` });
  }
}

async function collectAndProcessSnapshot() {
  if (!monitoredWindow || monitoredWindow.isDestroyed()) {
    return;
  }
  const snapshot = await collectSnapshot();
  tryResolveCalendar(snapshot, true);
  const keywords = parsedKeywords();
  const classified = classifySnapshot(snapshot, keywords);
  setRuntime({
    pageSummary: classified.summary,
    baseballSummary: classified.baseballContext && classified.baseballContext.summary ? classified.baseballContext.summary : '未検出',
  });
  if (settings.autoPageAudioControl) {
    const shouldEnable = shouldEnablePageAudio(classified.baseballContext, keywords);
    await setPageAudioMuted(!shouldEnable);
  }
  maybeNotifyDomMatch(classified.domMatch);
}

async function startMonitoringInternal() {
  if (runtime.isRunning) {
    return;
  }
  clearError();
  if (!monitoredWindow || monitoredWindow.isDestroyed()) {
    throw new Error('監視ページが開かれていません。先に URL を開いてください。');
  }
  runtime.isRunning = true;
  setRuntime({ statusMessage: '監視中' });
  await collectAndProcessSnapshot();
  if (monitorTimer) {
    clearInterval(monitorTimer);
  }
  monitorTimer = setInterval(() => {
    void collectAndProcessSnapshot().catch((error) => {
      surfaceError(error.message);
      stopMonitoring('失敗');
    });
  }, MONITOR_INTERVAL_MS);
}

async function stopMonitoring(statusMessage = '停止中') {
  if (monitorTimer) {
    clearInterval(monitorTimer);
    monitorTimer = null;
  }
  runtime.isRunning = false;
  restorePageAudioIfNeeded();
  setRuntime({ statusMessage });
}

function createControlWindow() {
  controlWindow = new BrowserWindow({
    width: 720,
    height: 920,
    backgroundColor: DODGERS_BLUE,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  controlWindow.loadFile(path.join(__dirname, 'index.html'));
  controlWindow.on('closed', () => {
    controlWindow = null;
  });
}

app.whenReady().then(() => {
  settings = loadSettings();
  createControlWindow();
  refreshCalendarStateFromSettings();
  scheduleAutomation();
  pushState();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createControlWindow();
      pushState();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

ipcMain.handle('state:get', () => publicState());

ipcMain.handle('settings:save', (_event, partial) => {
  settings = {
    ...settings,
    ...partial,
  };
  saveSettings();
  refreshCalendarStateFromSettings();
  scheduleAutomation();
  pushState();
  return publicState();
});

ipcMain.handle('automation:open-now', async () => {
  await openSourcePageNow();
  return publicState();
});

ipcMain.handle('automation:run-now', async () => {
  await executeScheduledAutomation('手動実行');
  return publicState();
});

ipcMain.handle('monitoring:start', async () => {
  await startMonitoringInternal();
  return publicState();
});

ipcMain.handle('monitoring:stop', async () => {
  await stopMonitoring();
  return publicState();
});
