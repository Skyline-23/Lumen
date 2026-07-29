using System.IO.Pipes;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Lumen.App;

internal sealed class LumenControlClient
{
    private const string PipeName = "Lumen.Management.v1";
    private static readonly byte[] ResponseAck = [0x06];
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task<ManagementSnapshot> SendAsync(object command, CancellationToken cancellationToken = default)
    {
        await using var pipe = new NamedPipeClientStream(
            ".",
            PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.WriteThrough);
        await pipe.ConnectAsync(3_000, cancellationToken);
        pipe.ReadMode = PipeTransmissionMode.Message;

        var request = JsonSerializer.SerializeToUtf8Bytes(command, JsonOptions);
        await pipe.WriteAsync(request, cancellationToken);
        await pipe.FlushAsync(cancellationToken);

        using var response = new MemoryStream();
        var buffer = new byte[16 * 1024];
        do
        {
            var read = await pipe.ReadAsync(buffer, cancellationToken);
            if (read == 0)
            {
                throw new IOException(AppStrings.Get("Error.ManagementConnectionClosed"));
            }
            response.Write(buffer, 0, read);
        } while (!pipe.IsMessageComplete);
        await pipe.WriteAsync(ResponseAck, cancellationToken);
        await pipe.FlushAsync(cancellationToken);

        var envelope = JsonSerializer.Deserialize<ManagementEnvelope>(response.ToArray(), JsonOptions)
            ?? throw new IOException(AppStrings.Get("Error.ManagementEmptyResponse"));
        if (!envelope.Ok || envelope.Payload is null)
        {
            throw new InvalidOperationException(envelope.Error?.Message ?? AppStrings.Get("Error.ManagementRejected"));
        }
        if (envelope.Payload.ProtocolVersion != 1)
        {
            throw new InvalidOperationException(AppStrings.Get("Error.ManagementIncompatible"));
        }
        return envelope.Payload;
    }
}

internal sealed record ManagementEnvelope(
    bool Ok,
    ManagementSnapshot? Payload,
    ManagementError? Error);

internal sealed record ManagementError(string Code, string Message);

internal sealed record ManagementSnapshot(
    int ProtocolVersion,
    string OwnerState,
    string? OwnerName,
    string HostName,
    int ControlPort,
    IReadOnlyList<LumenApplication> Applications,
    HostSettings Settings);

internal sealed record LumenApplication(
    uint Id,
    string Uuid,
    string Name,
    string Title,
    bool HdrSupported,
    bool IsAppCollectorGame);

internal sealed record HostSettings(
    WorkspaceSettings Workspace,
    GeneralSettings General,
    StreamingSettings Streaming,
    AudioSettings Audio,
    InputSettings Input,
    NetworkSettings Network,
    DiagnosticsSettings Diagnostics);

internal sealed record WorkspaceSettings(string Policy);
internal sealed record GeneralSettings(string Name, bool Discovery, string UpdateChannel, bool NotifyPreReleases);
internal sealed record StreamingSettings(string AdapterSelector, string OutputSelector, string FallbackDisplayMode);
internal sealed record AudioSettings(string Sink, bool StreamAudio);
internal sealed record InputSettings(
    bool Keyboard,
    bool Mouse,
    bool Controller,
    int BackButtonTimeoutMs,
    bool MapRightAltToWindowsKey,
    bool HighResolutionScrolling,
    bool NativePenTouch,
    bool RumbleForwarding);
internal sealed record NetworkSettings(
    string AddressFamily,
    int Port,
    bool Upnp,
    string RemoteAccessScope,
    string ExternalIpMode,
    string LanEncryption,
    string WanEncryption,
    int PingTimeoutMs,
    int FecPercentage);
internal sealed record DiagnosticsSettings(string LogLevel);
