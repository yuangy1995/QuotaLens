using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using QuotaLens.Core;
using QuotaLens.Providers;

namespace QuotaLens.Infrastructure;

public static class SafeErrors
{
    public static QuotaException Describe(Exception error) => error switch {
        QuotaException quota => quota,
        OperationCanceledException => new(FailureKind.Cancelled, "The operation was cancelled."),
        CryptographicException => new(FailureKind.Storage, "Encrypted credentials cannot be read. Existing files were not replaced."),
        SqliteException => new(FailureKind.Storage, "Local storage is busy or unavailable. Previous data was retained."),
        UnauthorizedAccessException => new(FailureKind.Storage, "The selected local files cannot be accessed with the current Windows user."),
        JsonException or InvalidDataException or FormatException or OverflowException => new(FailureKind.Incompatible, "The input or local data format is not supported. Previous data was retained."),
        RpcException rpc => new(FailureKind.Incompatible, $"This Codex CLI returned RPC error {rpc.Code}. Check the installed CLI version."),
        IOException => new(FailureKind.Storage, "A local file could not be read or saved. Previous data was retained."),
        _ => new(FailureKind.Incompatible, "The operation could not be completed. No successful result was assumed.") };
}
