# QuotaLens Windows

The initial native WinUI 3 client targets Windows 11 x64 and uses .NET 10. It is not a browser wrapper.

- [English setup, architecture, privacy, support boundaries and acceptance](../docs/windows.md)
- [简体中文使用、构建与验收说明](../docs/windows.zh-CN.md)
- [Windows integration change notes](../docs/windows-changelog.md)

From the repository root on Windows:

```powershell
dotnet run --project windows/QuotaLens.Core.Tests -c Release
dotnet run --project windows/QuotaLens.Providers.Tests -c Release
dotnet run --project windows/QuotaLens.Infrastructure.Tests -c Release
./windows/scripts/build.ps1
```

The ZIP is self-contained as a complete directory, not a single-file executable. CI validates the published app in isolated synthetic-data mode. Live provider authorization and real hardware acceptance remain separate. Keep the complete extracted directory and read `BUILD-INFO.json` to identify the source commit.
