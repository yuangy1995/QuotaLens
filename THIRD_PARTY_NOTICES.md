# Third-Party Notices

QuotaLens includes adapted portions of quota-monitor for Claude usage tracking,
Codex account usage, rate-limit compatibility, process discovery, and overlay
behavior.

## Windows binary dependencies

The Windows client references Microsoft.WindowsAppSDK and Microsoft.Data.Sqlite
and publishes their resolved runtime dependencies together with .NET. These
components retain their respective upstream licenses; the QuotaLens Apache
license does not replace them. The build collects available upstream license,
notice, copyright and NuGet package metadata files into `ThirdParty/` inside
each Windows ZIP. `ThirdParty/packages.json` records the resolved package names,
versions, package hashes and copied documents. Preserve these files and runtime
notices when redistributing the application. Build-only package metadata may
also appear in this inventory; it is not a list of only the shipped DLLs.

The original QuotaLens app artwork is reused for Windows, not replaced by an
unlicensed third-party icon. No font files are added to the repository.

## quota-monitor

Copyright (c) 2026 tjzhou

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
