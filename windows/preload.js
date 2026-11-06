const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('s17oApi', {
  getState: () => ipcRenderer.invoke('state:get'),
  saveSettings: (settings) => ipcRenderer.invoke('settings:save', settings),
  openNow: () => ipcRenderer.invoke('automation:open-now'),
  runAutomationNow: () => ipcRenderer.invoke('automation:run-now'),
  startMonitoring: () => ipcRenderer.invoke('monitoring:start'),
  stopMonitoring: () => ipcRenderer.invoke('monitoring:stop'),
  onStateChanged: (callback) => {
    const listener = (_event, state) => callback(state);
    ipcRenderer.on('state:changed', listener);
    return () => ipcRenderer.removeListener('state:changed', listener);
  },
});
