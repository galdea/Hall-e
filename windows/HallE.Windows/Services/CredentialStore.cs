using System.Security.Cryptography;
using System.Text;
using HallE.Core;

namespace HallE.Windows.Services;

public sealed class CredentialStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Hall-e Windows credential store v1");
    private readonly string _credentialDirectory;

    public CredentialStore(string rootPath)
    {
        if (string.IsNullOrWhiteSpace(rootPath))
        {
            throw new ArgumentException("A library root path is required.", nameof(rootPath));
        }

        _credentialDirectory = Path.Combine(Path.GetFullPath(rootPath), ".credentials");
    }

    public bool HasKey(TranscriptionProvider provider)
        => File.Exists(GetCredentialPath(provider));

    public string? GetKey(TranscriptionProvider provider)
    {
        var path = GetCredentialPath(provider);
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            var encrypted = File.ReadAllBytes(path);
            var plaintext = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
            try
            {
                return Encoding.UTF8.GetString(plaintext);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(plaintext);
            }
        }
        catch (CryptographicException exception)
        {
            throw new InvalidOperationException("The saved API key could not be decrypted for the current Windows user. Save the key again.", exception);
        }
    }

    public void SaveKey(TranscriptionProvider provider, string key)
    {
        var normalized = NormalizeKey(key);
        var path = GetCredentialPath(provider);
        Directory.CreateDirectory(_credentialDirectory);

        var plaintext = Encoding.UTF8.GetBytes(normalized);
        byte[]? encrypted = null;
        try
        {
            encrypted = ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser);
            var temporaryPath = path + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                using (var stream = new FileStream(
                    temporaryPath,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    4096,
                    FileOptions.WriteThrough))
                {
                    stream.Write(encrypted);
                    stream.Flush(true);
                }

                File.Move(temporaryPath, path, true);
            }
            finally
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            if (encrypted is not null)
            {
                CryptographicOperations.ZeroMemory(encrypted);
            }
        }
    }

    public void DeleteKey(TranscriptionProvider provider)
    {
        var path = GetCredentialPath(provider);
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }

    private string GetCredentialPath(TranscriptionProvider provider)
    {
        var name = provider switch
        {
            TranscriptionProvider.Deepgram => "deepgram.dpapi",
            TranscriptionProvider.Speechmatics => "speechmatics.dpapi",
            _ => throw new ArgumentOutOfRangeException(nameof(provider), provider, "Local transcription does not use an API key."),
        };
        return Path.Combine(_credentialDirectory, name);
    }

    internal static string NormalizeKey(string key)
    {
        var normalized = key?.Trim() ?? string.Empty;
        if (normalized.Length == 0
            || normalized.Any(char.IsWhiteSpace)
            || normalized.Any(char.IsControl))
        {
            throw new ArgumentException("Paste the secret API key only, without spaces or an Authorization prefix.", nameof(key));
        }

        return normalized;
    }
}
