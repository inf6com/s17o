using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace s17o;

/// <summary>
/// WASAPI ループバックでシステム音声を取得する。
/// macOS の SCStream / SystemAudioCapture に相当。
/// </summary>
public sealed class AudioCapture : IDisposable
{
    private readonly Action<WaveInEventArgs> _onBuffer;
    private readonly Action<string> _onSourceChange;
    private readonly Action<Exception> _onFailure;

    private WasapiLoopbackCapture? _capture;
    private volatile bool _started;

    public AudioCapture(
        Action<WaveInEventArgs> onBuffer,
        Action<string> onSourceChange,
        Action<Exception> onFailure)
    {
        _onBuffer = onBuffer;
        _onSourceChange = onSourceChange;
        _onFailure = onFailure;
    }

    public Task StartAsync()
    {
        if (_started) return Task.CompletedTask;

        try
        {
            var enumerator = new MMDeviceEnumerator();
            var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            _capture = new WasapiLoopbackCapture(device);

            _capture.DataAvailable += (_, e) =>
            {
                if (e.BytesRecorded > 0) _onBuffer(e);
            };
            _capture.RecordingStopped += (_, e) =>
            {
                if (e.Exception is { } ex) _onFailure(ex);
            };

            _capture.StartRecording();
            _started = true;

            var label = $"{device.FriendlyName} (loopback)";
            _onSourceChange(label);
        }
        catch (Exception ex)
        {
            _onFailure(ex);
        }

        return Task.CompletedTask;
    }

    public void Stop()
    {
        if (!_started) return;
        _started = false;
        try { _capture?.StopRecording(); }
        catch { /* ignore */ }
    }

    public WaveFormat? WaveFormat => _capture?.WaveFormat;

    public void Dispose()
    {
        Stop();
        _capture?.Dispose();
        _capture = null;
    }
}
