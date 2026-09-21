[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windowsRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $windowsRoot -Parent
$bytes = [IO.File]::ReadAllBytes((Join-Path $repoRoot 'Resources/AppIcon.icns'))
function Read-BigEndian32([byte[]]$value, [int]$offset) {
    if ($offset -lt 0 -or $offset + 4 -gt $value.Length) { throw 'Invalid ICNS header.' }
    return [long]$value[$offset] * 16777216 + [long]$value[$offset + 1] * 65536 + [long]$value[$offset + 2] * 256 + $value[$offset + 3]
}
if ($bytes.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'icns' -or (Read-BigEndian32 $bytes 4) -ne $bytes.Length) { throw 'Invalid source icon.' }
$images = [Collections.Generic.List[object]]::new()
$offset = 8
while ($offset -lt $bytes.Length) {
    if ($offset + 8 -gt $bytes.Length) { throw 'Truncated ICNS chunk.' }
    $kind = [Text.Encoding]::ASCII.GetString($bytes, $offset, 4)
    $length = Read-BigEndian32 $bytes ($offset + 4)
    if ($length -lt 8 -or $length -gt $bytes.Length - $offset) { throw 'Invalid ICNS chunk.' }
    if ($kind -in @('ic07', 'ic08')) {
        if ($length -lt 16) { throw 'Truncated PNG icon.' }
        [byte[]]$pngBytes = $bytes[($offset + 8)..($offset + $length - 1)]
        if ([Convert]::ToHexString([byte[]]($pngBytes[0..7])) -ne '89504E470D0A1A0A') { throw 'Expected PNG icon data.' }
        $size = if ($kind -eq 'ic07') { 128 } else { 256 }
        $images.Add(@{Size=$size; Bytes=$pngBytes})
    }
    $offset += $length
}
if ($images.Count -ne 2) { throw 'Expected both 128px and 256px source icons.' }
$destination = Join-Path $windowsRoot 'QuotaLens.Windows/Assets/AppIcon.ico'
New-Item -ItemType Directory -Force (Split-Path $destination -Parent) | Out-Null
$stream = [IO.MemoryStream]::new()
$writer = [IO.BinaryWriter]::new($stream)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$images.Count)
    $dataOffset = 6 + 16 * $images.Count
    # Do not reuse the typed byte-array variable for a hashtable loop element.
    foreach ($iconEntry in $images) {
        $dimension = if ($iconEntry.Size -eq 256) { 0 } else { $iconEntry.Size }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$iconEntry.Bytes.Length); $writer.Write([uint32]$dataOffset)
        $dataOffset += $iconEntry.Bytes.Length
    }
    foreach ($iconEntry in $images) { $writer.Write([byte[]]$iconEntry.Bytes) }
    $writer.Flush(); [IO.File]::WriteAllBytes($destination, $stream.ToArray())
} finally { $writer.Dispose(); $stream.Dispose() }
Write-Host 'Reused the original QuotaLens artwork for the Windows executable.'
