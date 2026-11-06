using System.Windows;
using System.Windows.Controls;

namespace s17o;

public partial class SettingsWindow : Window
{
    private readonly AppModel _model;
    private bool _loading = true;

    public SettingsWindow(AppModel model)
    {
        InitializeComponent();
        _model = model;
        model.PropertyChanged += (_, _) => Dispatcher.Invoke(Refresh);
        Load();
        Refresh();
        _loading = false;
    }

    private void Load()
    {
        AutoUrlBox.Text = _model.AutomationUrlText;
        StartDatePicker.SelectedDate = _model.AutomationStartDate.Date;
        StartTimeBox.Text = _model.AutomationStartDate.ToString("HH:mm");
        AutoOpenCheck.IsChecked  = _model.AutoOpenTargetPage;
        AutoStartCheck.IsChecked = _model.AutoStartMonitoringAtSchedule;
        AutoSoundCheck.IsChecked = _model.AutoSoundControlEnabled;
        AutoFrontCheck.IsChecked = _model.AutoBringToFrontEnabled;
    }

    private void Refresh()
    {
        AutoStatusText.Text = $"自動化: {_model.AutomationStatus}";
        CalendarStatusText.Text = $"カレンダー読取: {_model.CalendarStatus}";

        SetDetailList(PermissionList, new[]
        {
            ("AI エンジン",       _model.AiEngineStatus),
            ("状態",             _model.StatusMessage),
            ("音声自動化",        _model.SoundAutomationStatus),
            ("前面表示",          _model.ForegroundAutomationStatus),
        });

        SetDetailList(ProfileList, new[]
        {
            ("選択済みプロファイル", _model.ActiveProfileLabel),
            ("選択理由",           _model.ProfileReason),
        });

        SetDetailList(BrowserList, new[]
        {
            ("タイトル",      _model.PageTitle),
            ("URL",          _model.PageUrl),
            ("要約",          _model.PageSummary),
            ("野球文脈",      _model.BaseballSummary),
            ("最終 DOM 更新", _model.LastDomUpdate),
        });

        SetDetailList(AudioList, new[]
        {
            ("取得元",       _model.CaptureSource),
            ("最新 transcript", _model.Transcript),
            ("最新一致",     string.IsNullOrEmpty(_model.LastMatchKeyword)
                ? "まだありません"
                : $"{_model.LastMatchKeyword}\n{_model.LastMatchTranscript}"),
        });

        MatchList.Items.Clear();
        foreach (var ev in _model.RecentMatches.Take(10))
        {
            var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 6) };
            var header = new StackPanel { Orientation = Orientation.Horizontal };
            header.Children.Add(new TextBlock { Text = ev.Keyword, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 8, 0) });
            header.Children.Add(new TextBlock { Text = ev.Source == MatchSource.Audio ? "音声" : "DOM", Foreground = System.Windows.Media.Brushes.Gray, FontSize = 11 });
            header.Children.Add(new TextBlock { Text = ev.TimestampLabel, Foreground = System.Windows.Media.Brushes.Gray, FontSize = 11, Margin = new Thickness(8, 0, 0, 0) });
            panel.Children.Add(header);
            panel.Children.Add(new TextBlock { Text = ev.Details, TextWrapping = TextWrapping.Wrap, FontSize = 11 });

            var border = new Border
            {
                Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0xF0, 0xF0, 0xF0)),
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(8),
                Margin = new Thickness(0, 0, 0, 4),
                Child = panel
            };
            MatchList.Items.Add(border);
        }
    }

    private static void SetDetailList(ItemsControl list, (string Label, string Value)[] items)
    {
        list.Items.Clear();
        foreach (var (label, value) in items)
        {
            var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 4) };
            panel.Children.Add(new TextBlock { Text = label, FontSize = 10, Foreground = System.Windows.Media.Brushes.Gray });
            panel.Children.Add(new TextBlock
            {
                Text = string.IsNullOrEmpty(value) ? "まだありません" : value,
                TextWrapping = TextWrapping.Wrap,
            });
            var border = new Border
            {
                Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0xF4, 0xF4, 0xF4)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(8, 4, 8, 4),
                Margin = new Thickness(0, 0, 0, 4),
                Child = panel
            };
            list.Items.Add(border);
        }
    }

    // -----------------------------------------------------------------------
    // Event handlers
    // -----------------------------------------------------------------------

    private void OnAutoUrlChanged(object sender, TextChangedEventArgs e)
    {
        if (!_loading) _model.AutomationUrlText = AutoUrlBox.Text;
    }

    private void OnStartDateChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (StartDatePicker.SelectedDate is { } date)
        {
            var time = ParseTime(StartTimeBox.Text);
            _model.AutomationStartDate = date.Add(time);
        }
    }

    private void OnStartTimeChanged(object sender, TextChangedEventArgs e)
    {
        if (_loading) return;
        var date = StartDatePicker.SelectedDate ?? DateTime.Today;
        _model.AutomationStartDate = date.Add(ParseTime(StartTimeBox.Text));
    }

    private void OnToggleChanged(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _model.AutoOpenTargetPage             = AutoOpenCheck.IsChecked  == true;
        _model.AutoStartMonitoringAtSchedule  = AutoStartCheck.IsChecked == true;
        _model.AutoSoundControlEnabled        = AutoSoundCheck.IsChecked == true;
        _model.AutoBringToFrontEnabled        = AutoFrontCheck.IsChecked == true;
    }

    private async void OnOpenNowClick(object sender, RoutedEventArgs e) =>
        await _model.OpenConfiguredTargetPageNowAsync();

    private async void OnRunNowClick(object sender, RoutedEventArgs e) =>
        await _model.RunAutomationNowAsync();

    private static TimeSpan ParseTime(string text)
    {
        if (TimeSpan.TryParseExact(text.Trim(), "hh\\:mm", null, out var ts)) return ts;
        return TimeSpan.Zero;
    }
}
