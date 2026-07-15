using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace MuteCue.Desktop.Services;

public sealed record DiscordAuthorization(string AccessToken, string RefreshToken, long ExpiresAtUnixSeconds)
{
    public static DiscordAuthorization Empty { get; } = new(string.Empty, string.Empty, 0);
}

public sealed record DiscordPublicClient(string ApplicationId, string RedirectUri, string Detail)
{
    private static readonly JsonSerializerOptions SerializerOptions = new() { PropertyNameCaseInsensitive = true };

    public bool IsAvailable => ApplicationId.Length is >= 17 and <= 22 && RedirectUri == "http://127.0.0.1:47891/mute-cue/";

    public static DiscordPublicClient Load(string path)
    {
        try
        {
            var file = new FileInfo(path);
            if (!file.Exists || file.Length is <= 0 or > 65536) throw new InvalidDataException();
            var value = JsonSerializer.Deserialize<DiscordPublicClientDocument>(
                File.ReadAllText(path, Encoding.UTF8),
                SerializerOptions);
            if (value is null || value.SchemaVersion != 1 || string.IsNullOrWhiteSpace(value.ApplicationId) || !value.ApplicationId.All(char.IsDigit)) throw new InvalidDataException();
            return new DiscordPublicClient(value.ApplicationId.Trim(), value.RedirectUri?.Trim() ?? string.Empty, "Discord will ask for permission to read your own mute and deafen state locally.");
        }
        catch
        {
            return new DiscordPublicClient(string.Empty, string.Empty, "Discord sign-in is not configured in this build.");
        }
    }

    private sealed class DiscordPublicClientDocument
    {
        public int SchemaVersion { get; set; }
        public string? ApplicationId { get; set; }
        public string? RedirectUri { get; set; }
    }
}

public sealed class DiscordAuthorizationStore
{
    private readonly string _path;

    public DiscordAuthorizationStore()
        : this(AppPaths.DiscordAuthorizationPath)
    {
    }

    internal DiscordAuthorizationStore(string path)
    {
        _path = path;
    }

    public DiscordAuthorization Load()
    {
        try
        {
            var file = new FileInfo(_path);
            if (!file.Exists || file.Length is <= 0 or > 1024 * 1024) return DiscordAuthorization.Empty;
            var encrypted = Convert.FromBase64String(File.ReadAllText(_path, Encoding.UTF8).Trim());
            var plain = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            try
            {
                var document = JsonSerializer.Deserialize<DiscordAuthorizationDocument>(plain);
                if (document is null || document.AccessToken?.Length > 65536 || document.RefreshToken?.Length > 65536) return DiscordAuthorization.Empty;
                return new DiscordAuthorization(document.AccessToken ?? string.Empty, document.RefreshToken ?? string.Empty, Math.Max(0, document.ExpiresAtUnixSeconds));
            }
            finally { CryptographicOperations.ZeroMemory(plain); }
        }
        catch { return DiscordAuthorization.Empty; }
    }

    public void Save(DiscordAuthorization authorization)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var plain = JsonSerializer.SerializeToUtf8Bytes(new DiscordAuthorizationDocument { AccessToken = authorization.AccessToken, RefreshToken = authorization.RefreshToken, ExpiresAtUnixSeconds = authorization.ExpiresAtUnixSeconds });
        try
        {
            var encrypted = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
            var temporary = _path + ".tmp";
            File.WriteAllText(temporary, Convert.ToBase64String(encrypted), new UTF8Encoding(false));
            File.Move(temporary, _path, overwrite: true);
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    public void Forget()
    {
        if (File.Exists(_path)) File.Delete(_path);
    }

    private sealed class DiscordAuthorizationDocument
    {
        public string? AccessToken { get; set; }
        public string? RefreshToken { get; set; }
        public long ExpiresAtUnixSeconds { get; set; }
    }
}
