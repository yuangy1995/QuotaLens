# QuotaLens Windows

Native Windows implementation of QuotaLens, added alongside the existing macOS application. UI direction: the approved cyan/blue, light/dark Windows design. macOS source paths and local encrypted storage remain unchanged.

The first implementation commit contains the .NET 10 domain core, account/source boundaries, capacity forecasting port, shared Swift/C# fixtures, and Windows CI. Subsequent implementation commits add the provider, storage and WinUI application layers. This intermediate commit is not a Windows release.

## Development

Install the .NET 10 SDK. From `windows/`:

```powershell
dotnet run --project QuotaLens.Tests -c Release
```

The test executable is dependency-free and exits nonzero on any assertion failure. It covers shared forecast fixtures, quota cycle boundaries, delayed cloud counters, account isolation, cached-token semantics, stale-data retention and capability routing. No test uses real credentials or model calls.

Windows 11 x64 is the initial runtime validation target. WSL, Windows 10 and ARM64 must not be advertised as verified merely because code compiles.
