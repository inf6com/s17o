using System.Text.Json;
using System.Text.Json.Serialization;

namespace s17o;

// ---------------------------------------------------------------------------
// Profile definitions (same JSON schema as macOS)
// ---------------------------------------------------------------------------

public enum ProfileSchema { BaseballV1, GenericLiveV1 }

public record ProfileDefinition(
    string Id,
    string DisplayName,
    string Summary,
    ProfileSchema Schema,
    string PromptHint);

// ---------------------------------------------------------------------------
// ProfileRegistry
// ---------------------------------------------------------------------------

file static class ProfileRegistry
{
    private static readonly ProfileDefinition[] Presets =
    [
        new("baseball",          "Baseball",          "MLB.TV と mlb.com カレンダーの進行監視", ProfileSchema.BaseballV1,   "MLB.TV、mlb.com schedule、野球中継、打者、投手、回、広告状態を扱います。"),
        new("soccer",            "Soccer",            "サッカー中継の進行監視",                 ProfileSchema.GenericLiveV1, "association football、match clock、half、lineup、set piece を扱います。"),
        new("american_football", "American Football", "アメリカンフットボール中継の進行監視",     ProfileSchema.GenericLiveV1, "American football、down、drive、quarter、possession を扱います。"),
        new("music_concert",     "Music Concert",     "音楽ライブ・コンサート配信の進行監視",     ProfileSchema.GenericLiveV1, "concert、setlist、encore、intermission、performance segment を扱います。"),
        new("creator_stream",    "Creator Stream",    "配信者・クリエイターストリームの監視",     ProfileSchema.GenericLiveV1, "creator stream、segment change、break、ad break、guest change を扱います。"),
    ];

    public static Dictionary<string, ProfileDefinition> Load()
    {
        var dict = Presets.ToDictionary(p => p.Id);
        var dir = AppModel.ProfilesDirectory;
        if (!Directory.Exists(dir)) { Directory.CreateDirectory(dir); return dict; }

        foreach (var file in Directory.EnumerateFiles(dir, "*.json").OrderBy(f => f))
        {
            try
            {
                var json = File.ReadAllText(file);
                var obj = JsonSerializer.Deserialize<JsonElement>(json);
                var id = obj.GetProperty("id").GetString()!.Trim();
                var displayName = obj.GetProperty("displayName").GetString()!.Trim();
                var summary = obj.GetProperty("summary").GetString()!.Trim();
                var schemaRaw = obj.GetProperty("schema").GetString()!;
                var promptHint = obj.GetProperty("promptHint").GetString()!.Trim();

                if (!System.Text.RegularExpressions.Regex.IsMatch(id, @"^[a-z0-9_]+$"))
                    throw new InvalidDataException($"{Path.GetFileName(file)}: id は小文字英数字と underscore のみで指定してください。");

                var schema = schemaRaw switch
                {
                    "baseball_v1" => ProfileSchema.BaseballV1,
                    "generic_live_v1" => ProfileSchema.GenericLiveV1,
                    _ => throw new InvalidDataException($"不明な schema: {schemaRaw}")
                };

                dict[id] = new ProfileDefinition(id, displayName, summary, schema, promptHint);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Profile load error [{file}]: {ex.Message}");
            }
        }
        return dict;
    }
}

// ---------------------------------------------------------------------------
// AI output shapes (JSON from Edge Prompt API)
// ---------------------------------------------------------------------------

file record ProfileSelectionOutput(
    [property: JsonPropertyName("selectedProfile")] string SelectedProfile,
    [property: JsonPropertyName("reason")] string Reason,
    [property: JsonPropertyName("confidence")] double Confidence);

file record BaseballProfileOutput(
    [property: JsonPropertyName("pageKind")] string PageKind,
    [property: JsonPropertyName("gameState")] string GameState,
    [property: JsonPropertyName("summary")] string Summary,
    [property: JsonPropertyName("inningHalf")] string? InningHalf,
    [property: JsonPropertyName("currentActor")] string? CurrentActor,
    [property: JsonPropertyName("previousActor")] string? PreviousActor,
    [property: JsonPropertyName("nextActor")] string? NextActor,
    [property: JsonPropertyName("counterpart")] string? Counterpart,
    [property: JsonPropertyName("outs")] string? Outs,
    [property: JsonPropertyName("adState")] string AdState,
    [property: JsonPropertyName("playbackState")] string PlaybackState,
    [property: JsonPropertyName("watchUrl")] string? WatchUrl,
    [property: JsonPropertyName("scheduleDateText")] string? ScheduleDateText,
    [property: JsonPropertyName("scheduleTimeText")] string? ScheduleTimeText,
    [property: JsonPropertyName("scheduleTimeZone")] string? ScheduleTimeZone,
    [property: JsonPropertyName("confidence")] double Confidence);

file record GenericProfileOutput(
    [property: JsonPropertyName("summary")] string Summary,
    [property: JsonPropertyName("phase")] string? Phase,
    [property: JsonPropertyName("currentActor")] string? CurrentActor,
    [property: JsonPropertyName("nextActor")] string? NextActor,
    [property: JsonPropertyName("counterpart")] string? Counterpart,
    [property: JsonPropertyName("breakState")] string BreakState,
    [property: JsonPropertyName("confidence")] double Confidence);

// ---------------------------------------------------------------------------
// ProfileEngine
// ---------------------------------------------------------------------------

public sealed class ProfileEngine
{
    private readonly Dictionary<string, ProfileDefinition> _profiles;
    private BrowserController? _browser;

    public bool IsAvailable => _browser?.IsAiAvailable ?? false;

    public ProfileEngine()
    {
        _profiles = ProfileRegistry.Load();
    }

    public void AttachBrowser(BrowserController browser) => _browser = browser;

    public async Task<InterpretedPage> InterpretAsync(
        PageSnapshotEnvelope snapshot,
        List<string> keywords,
        DateTime referenceDate,
        CancellationToken ct)
    {
        if (_browser is null)
            throw new InvalidOperationException("BrowserController が接続されていません。");

        var digest = new SnapshotDigest(snapshot);
        var selection = await SelectProfileAsync(digest, ct);

        switch (selection.Profile.Schema)
        {
            case ProfileSchema.BaseballV1:
                var baseball = await ExtractBaseballContextAsync(digest, referenceDate, ct);
                var bbMatch = DomMatchResolver.Find(selection.Profile, new ProfilePayload(ProfilePayloadKind.Baseball, Baseball: baseball), keywords, digest.Signature);
                return new InterpretedPage(selection, baseball.Summary, new ProfilePayload(ProfilePayloadKind.Baseball, Baseball: baseball), bbMatch);

            default:
                var generic = await ExtractGenericContextAsync(selection.Profile, digest, ct);
                var genMatch = DomMatchResolver.Find(selection.Profile, new ProfilePayload(ProfilePayloadKind.Generic, Generic: generic), keywords, digest.Signature);
                return new InterpretedPage(selection, generic.Summary, new ProfilePayload(ProfilePayloadKind.Generic, Generic: generic), genMatch);
        }
    }

    // -----------------------------------------------------------------------
    // Profile selection
    // -----------------------------------------------------------------------

    private async Task<ProfileSelectionState> SelectProfileAsync(SnapshotDigest digest, CancellationToken ct)
    {
        var catalog = string.Join("\n", _profiles.Values
            .OrderBy(p => p.Id)
            .Select(p => $"{p.Id}: {p.DisplayName} / {p.Summary} / {p.PromptHint}"));

        var systemPrompt = $"""
            You are the profile selector for s17o.
            You must choose exactly one profile id from the supplied profile catalog.
            Use only the provided local DOM snapshot.
            Do not invent page content that is not visible.
            Valid profile ids:
            {catalog}
            Respond with ONLY valid JSON in this exact shape:
            {{"selectedProfile":"<id>","reason":"<short reason>","confidence":<0.0-1.0>}}
            """;

        var json = await _browser!.PromptAiAsync(systemPrompt, digest.PromptBody(), ct);
        var output = JsonSerializer.Deserialize<ProfileSelectionOutput>(ExtractJson(json))
            ?? throw new InvalidOperationException("profile selection の JSON 解析に失敗しました。");

        if (!_profiles.TryGetValue(output.SelectedProfile, out var profile))
            throw new InvalidOperationException($"model が不正な profile を返しました: {output.SelectedProfile}");

        return new ProfileSelectionState(profile, output.Confidence, output.Reason);
    }

    // -----------------------------------------------------------------------
    // Baseball extraction
    // -----------------------------------------------------------------------

    private async Task<BaseballContext> ExtractBaseballContextAsync(
        SnapshotDigest digest, DateTime referenceDate, CancellationToken ct)
    {
        var systemPrompt = """
            You extract structured baseball state for s17o from a local DOM snapshot.
            Use only visible local DOM content. Do not guess hidden data.
            If a field is missing, return null.
            watchUrl must be one of the provided visible links when the page is a schedule page.
            scheduleDateText and scheduleTimeText must be copied from visible DOM text as-is.
            scheduleTimeZone must be a short timezone label such as PT, PDT, ET, EDT, JST when visible. If not visible, return null.
            currentActor = current batter. nextActor = next batter or on deck. previousActor = previous batter. counterpart = pitcher.
            Respond with ONLY valid JSON matching:
            {"pageKind":"<calendar|live_game|watch_stream|ad_break|postgame|unknown>",
             "gameState":"<scheduled|live|paused|postgame|unknown>",
             "summary":"<short>","inningHalf":null,"currentActor":null,"previousActor":null,
             "nextActor":null,"counterpart":null,"outs":null,
             "adState":"<live|ad|stuck|unknown>","playbackState":"<playing|paused|buffering|stopped|unknown>",
             "watchUrl":null,"scheduleDateText":null,"scheduleTimeText":null,"scheduleTimeZone":null,
             "confidence":0.0}
            """;

        var json = await _browser!.PromptAiAsync(systemPrompt, digest.PromptBody(), ct);
        var o = JsonSerializer.Deserialize<BaseballProfileOutput>(ExtractJson(json))
            ?? throw new InvalidOperationException("baseball extraction の JSON 解析に失敗しました。");

        Uri? watchUrl = null;
        if (!string.IsNullOrEmpty(o.WatchUrl))
            Uri.TryCreate(o.WatchUrl, UriKind.Absolute, out watchUrl);

        var startDate = ScheduleDateResolver.Resolve(o.ScheduleDateText, o.ScheduleTimeText, o.ScheduleTimeZone, referenceDate);

        return new BaseballContext(
            o.PageKind, o.GameState, o.InningHalf,
            o.CurrentActor, o.PreviousActor, o.NextActor,
            o.Counterpart, o.Outs, o.AdState, o.PlaybackState,
            watchUrl?.AbsoluteUri, o.ScheduleDateText, o.ScheduleTimeText,
            o.ScheduleTimeZone, startDate, o.Confidence);
    }

    // -----------------------------------------------------------------------
    // Generic extraction
    // -----------------------------------------------------------------------

    private async Task<GenericProfileContext> ExtractGenericContextAsync(
        ProfileDefinition profile, SnapshotDigest digest, CancellationToken ct)
    {
        var systemPrompt = $"""
            You extract structured state for the {profile.Id} profile from a local DOM snapshot.
            Use only visible local DOM content. Do not guess hidden data.
            summary must be short and factual.
            phase should capture the current segment of the live event.
            currentActor, nextActor, counterpart should be factual visible names or roles if present.
            Profile summary: {profile.Summary}
            Profile hint: {profile.PromptHint}
            Respond with ONLY valid JSON matching:
            {{"summary":"","phase":null,"currentActor":null,"nextActor":null,"counterpart":null,
              "breakState":"<live|break|ad|stuck|unknown>","confidence":0.0}}
            """;

        var json = await _browser!.PromptAiAsync(systemPrompt, digest.PromptBody(), ct);
        var o = JsonSerializer.Deserialize<GenericProfileOutput>(ExtractJson(json))
            ?? throw new InvalidOperationException("generic extraction の JSON 解析に失敗しました。");

        return new GenericProfileContext(o.Summary, o.Phase, o.CurrentActor, o.NextActor, o.Counterpart, o.BreakState, o.Confidence);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private static string ExtractJson(string text)
    {
        var start = text.IndexOf('{');
        var end = text.LastIndexOf('}');
        if (start < 0 || end < start) return text;
        return text[start..(end + 1)];
    }
}

// ---------------------------------------------------------------------------
// SnapshotDigest
// ---------------------------------------------------------------------------

file sealed class SnapshotDigest
{
    public string Title { get; }
    public string Url { get; }
    public IReadOnlyList<string> Headings { get; }
    public IReadOnlyList<string> Highlights { get; }
    public string VisibleText { get; }
    public IReadOnlyList<VisibleLink> Links { get; }

    public SnapshotDigest(PageSnapshotEnvelope s)
    {
        Title = s.Page.Title;
        Url = s.Page.Url;
        Headings = s.Page.Headings;
        Highlights = s.Page.Highlights;
        VisibleText = s.Page.VisibleText;
        Links = s.Page.Links ?? [];
    }

    public string Signature =>
        string.Join("\n", Title, Url,
            string.Join("|", Headings),
            string.Join("|", Highlights),
            string.Join("|", Links.Select(l => $"{l.Text}\t{l.Href}")),
            VisibleText);

    public string PromptBody()
    {
        var linkBlock = Links.Count == 0 ? "[]"
            : string.Join("\n", Links.Select(l => $"- text: {l.Text}\n  href: {l.Href}"));
        return $"""
            title:
            {Title}

            url:
            {Url}

            headings:
            {string.Join("\n", Headings)}

            highlights:
            {string.Join("\n", Highlights)}

            links:
            {linkBlock}

            visible_text:
            {VisibleText}
            """;
    }
}

// ---------------------------------------------------------------------------
// DomMatchResolver
// ---------------------------------------------------------------------------

file static class DomMatchResolver
{
    public static DomMatch? Find(ProfileDefinition profile, ProfilePayload payload, List<string> keywords, string signature)
    {
        if (keywords.Count == 0) return null;
        var normed = keywords.Select(Normalize).ToList();

        if (profile.Schema == ProfileSchema.BaseballV1 && payload.Baseball is { } bb)
        {
            var fields = new (string Label, string? Value)[]
            {
                ("現在打者", bb.CurrentBatter),
                ("前打者", bb.PreviousBatter),
                ("次打者", bb.OnDeck),
                ("投手", bb.Pitcher),
            };
            foreach (var (label, value) in fields)
            {
                if (value is null) continue;
                var nv = Normalize(value);
                var kw = normed.FirstOrDefault(k => nv.Contains(k, StringComparison.OrdinalIgnoreCase));
                if (kw is not null)
                {
                    var details = $"{label}で {kw} を検出しました: {value}{(bb.Summary.Length > 0 ? $" ({bb.Summary})" : "")}";
                    return new DomMatch(kw, label, details, signature);
                }
            }
            return null;
        }

        if (payload.Generic is { } gen)
        {
            var fields = new[] { gen.CurrentActor, gen.NextActor, gen.Counterpart, gen.Summary, gen.Phase }
                .Where(f => !string.IsNullOrEmpty(f)).Select(f => f!);
            foreach (var field in fields)
            {
                var nv = Normalize(field);
                var kw = normed.FirstOrDefault(k => nv.Contains(k, StringComparison.OrdinalIgnoreCase));
                if (kw is not null)
                    return new DomMatch(kw, "profile", $"profile で {kw} を検出しました: {field}", signature);
            }
        }
        return null;
    }

    private static string Normalize(string text) =>
        text.ToLowerInvariant().Normalize(System.Text.NormalizationForm.FormKD);
}

// ---------------------------------------------------------------------------
// ScheduleDateResolver (deterministic date-text parsing; text is AI-extracted)
// ---------------------------------------------------------------------------

file static class ScheduleDateResolver
{
    private static readonly System.Text.RegularExpressions.Regex TimeRx = new(
        @"\b(\d{1,2}):(\d{2})\s*([AaPp][Mm])\b", System.Text.RegularExpressions.RegexOptions.Compiled);
    private static readonly System.Text.RegularExpressions.Regex MonthRx = new(
        @"\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+(\d{1,2})\b",
        System.Text.RegularExpressions.RegexOptions.Compiled | System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    public static DateTime? Resolve(string? dateText, string? timeText, string? tzLabel, DateTime referenceDate)
    {
        if (string.IsNullOrWhiteSpace(dateText) || string.IsNullOrWhiteSpace(timeText)) return null;

        var timeMatch = TimeRx.Match(timeText);
        if (!timeMatch.Success) return null;

        if (!int.TryParse(timeMatch.Groups[1].Value, out var rawHour)) return null;
        if (!int.TryParse(timeMatch.Groups[2].Value, out var minute)) return null;
        var period = timeMatch.Groups[3].Value.ToUpperInvariant();
        var hour = period == "AM" ? (rawHour == 12 ? 0 : rawHour) : (rawHour == 12 ? 12 : rawHour + 12);

        var tz = ResolveTimeZone(tzLabel ?? InferTimeZone(dateText + " " + timeText));

        var monthDay = ParseMonthDay(dateText, referenceDate);
        if (monthDay is null) return null;

        var cal = System.Globalization.CultureInfo.InvariantCulture.Calendar;
        var dt = new DateTime(monthDay.Value.Year, monthDay.Value.Month, monthDay.Value.Day, hour, minute, 0,
            DateTimeKind.Unspecified);
        return TimeZoneInfo.ConvertTimeToUtc(dt, tz ?? TimeZoneInfo.Local);
    }

    private static (int Year, int Month, int Day)? ParseMonthDay(string text, DateTime reference)
    {
        var m = MonthRx.Match(text);
        if (m.Success)
        {
            var month = MonthIndex(m.Groups[1].Value);
            if (month > 0 && int.TryParse(m.Groups[2].Value, out var day))
                return (AdjustedYear(month, day, reference), month, day);
        }
        var numericRx = System.Text.RegularExpressions.Regex.Match(text, @"\b(\d{1,2})/(\d{1,2})\b");
        if (numericRx.Success &&
            int.TryParse(numericRx.Groups[1].Value, out var m2) &&
            int.TryParse(numericRx.Groups[2].Value, out var d2))
            return (AdjustedYear(m2, d2, reference), m2, d2);
        return null;
    }

    private static int AdjustedYear(int month, int day, DateTime reference)
    {
        if (month < reference.Month - 1) return reference.Year + 1;
        if (month == reference.Month - 1 && day < reference.Day) return reference.Year + 1;
        return reference.Year;
    }

    private static string? InferTimeZone(string text)
    {
        var upper = text.ToUpperInvariant();
        foreach (var label in new[] { "JST", "PDT", "PST", "PT", "EDT", "EST", "ET", "CDT", "CST", "CT", "MDT", "MST", "MT" })
            if (upper.Contains(label)) return label;
        return null;
    }

    private static TimeZoneInfo? ResolveTimeZone(string? label) => label?.ToUpperInvariant() switch
    {
        "JST" => TimeZoneInfo.FindSystemTimeZoneById("Tokyo Standard Time"),
        "PT" or "PDT" or "PST" => TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time"),
        "MT" or "MDT" or "MST" => TimeZoneInfo.FindSystemTimeZoneById("Mountain Standard Time"),
        "CT" or "CDT" or "CST" => TimeZoneInfo.FindSystemTimeZoneById("Central Standard Time"),
        "ET" or "EDT" or "EST" => TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time"),
        _ => null
    };

    private static int MonthIndex(string name) => name.ToLowerInvariant() switch
    {
        "jan" or "january" => 1, "feb" or "february" => 2,
        "mar" or "march" => 3, "apr" or "april" => 4,
        "may" => 5, "jun" or "june" => 6,
        "jul" or "july" => 7, "aug" or "august" => 8,
        "sep" or "sept" or "september" => 9, "oct" or "october" => 10,
        "nov" or "november" => 11, "dec" or "december" => 12,
        _ => 0
    };
}
