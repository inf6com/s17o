using System.Drawing;
using System.Windows;
using System.Windows.Forms;
using Application = System.Windows.Application;

namespace s17o;

public partial class App : Application
{
    private NotifyIcon? _trayIcon;
    private MainWindow? _mainWindow;
    private AppModel? _model;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _model = new AppModel();
        _mainWindow = new MainWindow(_model);

        SetupTrayIcon();

        _mainWindow.Show();
    }

    private void SetupTrayIcon()
    {
        _trayIcon = new NotifyIcon
        {
            Text = AppModel.AppDisplayName,
            Visible = true,
            Icon = TrayIconResource(),
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add("開く", null, (_, _) => ShowMainWindow());
        menu.Items.Add("-");
        menu.Items.Add("終了", null, (_, _) => Shutdown());
        _trayIcon.ContextMenuStrip = menu;
        _trayIcon.DoubleClick += (_, _) => ShowMainWindow();
    }

    private void ShowMainWindow()
    {
        if (_mainWindow is null) return;
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    private static Icon TrayIconResource()
    {
        var path = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Resources", "icon.ico");
        return System.IO.File.Exists(path) ? new Icon(path) : SystemIcons.Application;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIcon?.Dispose();
        _model?.Dispose();
        base.OnExit(e);
    }
}
