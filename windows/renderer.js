function $(id) {
  return document.getElementById(id);
}

function applyState(state) {
  const settings = state.settings;
  $('keywordsText').value = settings.keywordsText || '';
  $('automationURLText').value = settings.automationURLText || '';
  $('automationStartAt').value = settings.automationStartAt || '';
  $('autoOpenTargetPage').checked = Boolean(settings.autoOpenTargetPage);
  $('autoStartMonitoringAtSchedule').checked = Boolean(settings.autoStartMonitoringAtSchedule);
  $('autoPageAudioControl').checked = Boolean(settings.autoPageAudioControl);

  $('statusMessage').textContent = state.runtime.statusMessage;
  $('automationStatus').textContent = state.runtime.automationStatus;
  $('calendarStatus').textContent = state.runtime.calendarStatus;
  $('soundStatus').textContent = state.runtime.soundStatus;
  $('monitoredPage').textContent = state.monitoredPageTitle ? `${state.monitoredPageTitle}\n${state.monitoredPageURL}` : 'まだありません';
  $('pageSummary').textContent = state.runtime.pageSummary;
  $('baseballSummary').textContent = state.runtime.baseballSummary;
  $('lastMatch').textContent = state.runtime.lastMatch;
  $('lastError').textContent = state.runtime.lastError || 'なし';
}

function collectSettings() {
  return {
    keywordsText: $('keywordsText').value,
    automationURLText: $('automationURLText').value.trim(),
    automationStartAt: $('automationStartAt').value,
    autoOpenTargetPage: $('autoOpenTargetPage').checked,
    autoStartMonitoringAtSchedule: $('autoStartMonitoringAtSchedule').checked,
    autoPageAudioControl: $('autoPageAudioControl').checked,
  };
}

async function saveSettings() {
  const state = await window.s17oApi.saveSettings(collectSettings());
  applyState(state);
}

window.addEventListener('DOMContentLoaded', async () => {
  const unsubscribe = window.s17oApi.onStateChanged(applyState);
  window.addEventListener('beforeunload', () => {
    unsubscribe();
  });

  applyState(await window.s17oApi.getState());

  $('saveButton').addEventListener('click', async () => {
    await saveSettings();
  });

  $('openNowButton').addEventListener('click', async () => {
    await saveSettings();
    applyState(await window.s17oApi.openNow());
  });

  $('runNowButton').addEventListener('click', async () => {
    await saveSettings();
    applyState(await window.s17oApi.runAutomationNow());
  });

  $('startMonitoringButton').addEventListener('click', async () => {
    await saveSettings();
    applyState(await window.s17oApi.startMonitoring());
  });

  $('stopMonitoringButton').addEventListener('click', async () => {
    applyState(await window.s17oApi.stopMonitoring());
  });
});
