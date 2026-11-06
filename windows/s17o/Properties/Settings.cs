using System.Configuration;
using System.Runtime.CompilerServices;

namespace s17o.Properties;

internal sealed class Settings : ApplicationSettingsBase
{
    private static readonly Settings _default = (Settings)Synchronized(new Settings());
    public static Settings Default => _default;

    [UserScopedSetting, DefaultSettingValue("Ohtani\nShohei Ohtani")]
    public string Keywords
    {
        get => (string)this[nameof(Keywords)];
        set { this[nameof(Keywords)] = value; }
    }

    [UserScopedSetting, DefaultSettingValue("")]
    public string AutomationUrl
    {
        get => (string)this[nameof(AutomationUrl)];
        set { this[nameof(AutomationUrl)] = value; }
    }

    [UserScopedSetting, DefaultSettingValue("")]
    public DateTime AutomationStartDate
    {
        get => (DateTime)(this[nameof(AutomationStartDate)] ?? default(DateTime));
        set { this[nameof(AutomationStartDate)] = value; }
    }

    [UserScopedSetting, DefaultSettingValue("False")]
    public bool AutoOpenTargetPage
    {
        get => (bool)this[nameof(AutoOpenTargetPage)];
        set { this[nameof(AutoOpenTargetPage)] = value; }
    }

    [UserScopedSetting, DefaultSettingValue("False")]
    public bool AutoStartMonitoring
    {
        get => (bool)this[nameof(AutoStartMonitoring)];
        set { this[nameof(AutoStartMonitoring)] = value; }
    }

    [UserScopedSetting, DefaultSettingValue("False")]
    public bool AutoSoundControl
    {
        get => (bool)this[nameof(AutoSoundControl)];
        set { this[nameof(AutoSoundControl)] = value; }
    }

    [UserScopedSetting, DefaultSettingValue("False")]
    public bool AutoBringToFront
    {
        get => (bool)this[nameof(AutoBringToFront)];
        set { this[nameof(AutoBringToFront)] = value; }
    }
}
