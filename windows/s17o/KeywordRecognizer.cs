using NAudio.Wave;
using Windows.Media.SpeechRecognition;

namespace s17o;

/// <summary>
/// Windows.Media.SpeechRecognition (on-device) でキーワードを検出する。
/// macOS の KeywordRecognizer + SFSpeechRecognizer に相当。
/// </summary>
public sealed class KeywordRecognizer : IDisposable
{
    private readonly List<string> _keywords;
    private readonly Action<string> _onTranscript;
    private readonly Action<string, string> _onMatch;
    private readonly Action<Exception> _onFailure;

    private SpeechRecognizer? _recognizer;
    private CancellationTokenSource? _cts;

    public KeywordRecognizer(
        List<string> keywords,
        Action<string> onTranscript,
        Action<string, string> onMatch,
        Action<Exception> onFailure)
    {
        _keywords = keywords;
        _onTranscript = onTranscript;
        _onMatch = onMatch;
        _onFailure = onFailure;

        _ = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        try
        {
            _recognizer = new SpeechRecognizer();

            // キーワードヒントを追加して認識精度を上げる
            var listConstraint = new SpeechRecognitionListConstraint(_keywords, "keywords");
            _recognizer.Constraints.Add(listConstraint);

            await _recognizer.CompileConstraintsAsync();

            _recognizer.ContinuousRecognitionSession.ResultGenerated += OnResultGenerated;
            _recognizer.ContinuousRecognitionSession.AutoStopSilenceTimeout = TimeSpan.FromSeconds(30);

            _cts = new CancellationTokenSource();
            await _recognizer.ContinuousRecognitionSession.StartAsync();
        }
        catch (Exception ex)
        {
            _onFailure(ex);
        }
    }

    private void OnResultGenerated(SpeechContinuousRecognitionSession sender, SpeechContinuousRecognitionResultGeneratedEventArgs args)
    {
        var text = args.Result.Text.Trim();
        if (string.IsNullOrEmpty(text)) return;

        _onTranscript(text);

        var matched = DetectKeyword(text);
        if (matched is not null) _onMatch(matched, text);
    }

    /// <summary>
    /// PCM バッファを受け取る口（macOS 互換 API）。
    /// Windows では SpeechRecognizer が直接マイク/ループバックを読むため使用しない。
    /// AudioCapture → KeywordRecognizer のパイプラインが不要な場合はスタブとして残す。
    /// </summary>
    public void Append(WaveInEventArgs _) { /* Windows では SpeechRecognizer が音源を管理する */ }

    public void Stop()
    {
        _cts?.Cancel();
        try { _recognizer?.ContinuousRecognitionSession.StopAsync().AsTask().Wait(1000); }
        catch { /* ignore */ }
    }

    private string? DetectKeyword(string transcript)
    {
        var normTranscript = Normalize(transcript);
        var tokens = Tokenize(normTranscript);

        foreach (var keyword in _keywords)
        {
            var normKw = Normalize(keyword);
            if (normTranscript.Contains(normKw, StringComparison.OrdinalIgnoreCase))
                return keyword;

            var kwTokens = Tokenize(normKw);
            if (kwTokens.Length == 0) continue;

            var bestScore = 0.0;
            foreach (var len in CandidateLengths(kwTokens.Length))
            {
                if (len > tokens.Length) continue;
                for (var start = 0; start <= tokens.Length - len; start++)
                {
                    var window = string.Join(" ", tokens[start..(start + len)]);
                    var score = Similarity(normKw, window);
                    if (score > bestScore) bestScore = score;
                }
            }
            if (bestScore >= Threshold(kwTokens.Length)) return keyword;
        }
        return null;
    }

    private static int[] CandidateLengths(int exact) =>
        [Math.Max(1, exact - 1), exact, exact + 1];

    private static double Threshold(int tokenCount) => tokenCount <= 1 ? 0.82 : 0.76;

    private static string Normalize(string text) =>
        System.Text.RegularExpressions.Regex.Replace(
            text.ToLowerInvariant().Normalize(System.Text.NormalizationForm.FormKD),
            @"[^a-z0-9 ]+", " ").Trim();

    private static string[] Tokenize(string text) =>
        text.Split(' ', StringSplitOptions.RemoveEmptyEntries);

    private static double Similarity(string a, string b)
    {
        var dist = Levenshtein(a, b);
        var longest = Math.Max(a.Length, b.Length);
        return longest == 0 ? 1.0 : 1.0 - (double)dist / longest;
    }

    private static int Levenshtein(string a, string b)
    {
        if (a.Length == 0) return b.Length;
        if (b.Length == 0) return a.Length;
        var prev = Enumerable.Range(0, b.Length + 1).ToArray();
        for (var i = 0; i < a.Length; i++)
        {
            var curr = new int[b.Length + 1];
            curr[0] = i + 1;
            for (var j = 0; j < b.Length; j++)
                curr[j + 1] = Math.Min(
                    Math.Min(curr[j] + 1, prev[j + 1] + 1),
                    prev[j] + (a[i] == b[j] ? 0 : 1));
            prev = curr;
        }
        return prev[b.Length];
    }

    public void Dispose()
    {
        Stop();
        _cts?.Dispose();
        _recognizer?.Dispose();
    }
}
