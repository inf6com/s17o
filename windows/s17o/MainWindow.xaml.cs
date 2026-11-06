using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace s17o;

public partial class MainWindow : Window
{
    private readonly AppModel _model;
    private readonly BrowserController _browser;

    public MainWindow(AppModel model)
    {
        InitializeComponent();
        _model = model;

        _browser = new BrowserController(WebView);
        var profileEngine = new ProfileEngine();
        model.AttachBrowserController(_browser, profileEngine);

        DataContext = model;
        KeywordsBox.Text = model.KeywordsText;
        KeywordsBox.TextChanged += (_, _) => model.KeywordsText = KeywordsBox.Text;

        model.PropertyChanged += OnModelPropertyChanged;

        _ = InitBrowserAsync();
    }

    private async Task InitBrowserAsync()
    {
        await _browser.InitializeAsync();
        RefreshStatusBlocks();
    }

    // -----------------------------------------------------------------------
    // Status blocks
    // -----------------------------------------------------------------------

    private void RefreshStatusBlocks()
    {
        SetBlock(BlockStatus,   "状態",         _model.StatusMessage);
        SetBlock(BlockTab,      "AI エンジン",   _model.AiEngineStatus);
        SetBlock(BlockAuto,     "自動化",        _model.AutomationStatus);
        SetBlock(BlockProfile,  "プロファイル",  _model.ActiveProfileLabel);
        SetBlock(BlockBaseball, "野球文脈",      _model.BaseballSummary);

        ErrorText.Text = _model.LastError;
        ErrorText.Visibility = string.IsNullOrEmpty(_model.LastError)
            ? Visibility.Collapsed : Visibility.Visible;
    }

    private static void SetBlock(Border border, string title, string value)
    {
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 10,
            Foreground = System.Windows.Media.Brushes.Gray,
        });
        panel.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(value) ? "まだありません" : value,
            FontWeight = FontWeights.Bold,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 120,
        });
        border.Child = panel;
    }

    private void OnModelPropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        Dispatcher.Invoke(RefreshStatusBlocks);

    // -----------------------------------------------------------------------
    // Button handlers
    // -----------------------------------------------------------------------

    private async void OnStartClick(object sender, RoutedEventArgs e)
    {
        ((Button)sender).IsEnabled = false;
        await _model.StartMonitoringAsync();
        ((Button)sender).IsEnabled = true;
    }

    private async void OnStopClick(object sender, RoutedEventArgs e) =>
        await _model.StopMonitoringAsync();

    private void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        var dlg = new SettingsWindow(_model) { Owner = this };
        dlg.ShowDialog();
    }

    // -----------------------------------------------------------------------
    // Browser navigation
    // -----------------------------------------------------------------------

    private void OnBackClick(object sender, RoutedEventArgs e) =>
        WebView.CoreWebView2?.GoBack();

    private void OnForwardClick(object sender, RoutedEventArgs e) =>
        WebView.CoreWebView2?.GoForward();

    private void OnReloadClick(object sender, RoutedEventArgs e) =>
        WebView.CoreWebView2?.Reload();

    private void OnNavigateClick(object sender, RoutedEventArgs e) =>
        TryNavigate(AddressBar.Text);

    private void OnAddressBarKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Return) TryNavigate(AddressBar.Text);
    }

    private void TryNavigate(string input)
    {
        var url = input.Trim();
        if (!url.StartsWith("http://") && !url.StartsWith("https://"))
            url = "https://" + url;
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
            _browser.Navigate(uri);
    }

    private void OnNavigationStarting(object? sender, Microsoft.Web.WebView2.Core.CoreWebView2NavigationStartingEventArgs e) =>
        AddressBar.Text = e.Uri;

    private void OnNavigationCompleted(object? sender, Microsoft.Web.WebView2.Core.CoreWebView2NavigationCompletedEventArgs e)
    {
        if (WebView.CoreWebView2?.Source is { } src)
            AddressBar.Text = src;
    }

    // -----------------------------------------------------------------------
    // Close → hide to tray
    // -----------------------------------------------------------------------

    private void OnWindowClosing(object? sender, CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
    }
}
