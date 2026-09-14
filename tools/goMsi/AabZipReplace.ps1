param(
    [Parameter(Mandatory = $true)][string]$SourceAab,
    [Parameter(Mandatory = $true)][string]$DestAab,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [string]$ManifestEntry = "base/manifest/AndroidManifest.xml"
)

$ErrorActionPreference = "Stop"

function Normalize-ZipPath([string]$PathValue) {
    return (($PathValue -replace "\\", "/").TrimStart("/"))
}

function Get-CompressionMethodField($Entry) {
    $flags = [Reflection.BindingFlags]"NonPublic,Instance"
    $type = $Entry.GetType()
    $field = $type.GetField("_storedCompressionMethod", $flags)
    if (-not $field) {
        $field = $type.GetField("_compressionMethod", $flags)
    }
    return $field
}

function Test-ShouldSkip([string]$EntryName, [string]$ManifestName) {
    $name = Normalize-ZipPath $EntryName
    if ([string]::Equals($name, $ManifestName, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($name.Equals("META-INF", [StringComparison]::OrdinalIgnoreCase) -or
        $name.StartsWith("META-INF/", [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $false
}

function Get-IsStoredEntry($Entry) {
    $field = Get-CompressionMethodField $Entry
    if ($field) {
        try {
            return ([int]$field.GetValue($Entry) -eq 0)
        } catch {
        }
    }
    if ($Entry.Length -eq 0) {
        return $true
    }
    return ($Entry.CompressedLength -ge $Entry.Length)
}

function Set-EntryCompressionMethod($Entry, $MethodValue) {
    $field = Get-CompressionMethodField $Entry
    if (-not $field -or $null -eq $MethodValue) {
        return
    }
    try {
        $typed = [Enum]::ToObject($field.FieldType, [int]$MethodValue)
        $field.SetValue($Entry, $typed)
    } catch {
    }
}

try {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (-not (Test-Path -LiteralPath $SourceAab)) {
        throw "Source AAB not found: $SourceAab"
    }
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Patched manifest not found: $ManifestPath"
    }

    $manifestName = Normalize-ZipPath $ManifestEntry
    $destDir = Split-Path -Parent $DestAab
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir | Out-Null
    }

    $tmpAab = "$DestAab.rewriting"
    if (Test-Path -LiteralPath $tmpAab) {
        Remove-Item -LiteralPath $tmpAab -Force
    }

    $srcSize = (Get-Item -LiteralPath $SourceAab).Length
    Write-Host "[INFO] Rewriting AAB without 7-Zip update..."
    Write-Host "[INFO] Source=$SourceAab"
    Write-Host "[INFO] Dest=$DestAab"
    Write-Host "[INFO] SourceSize=$srcSize"
    Write-Host "[INFO] This copies all entries and may take several minutes for large AABs."

    $srcStream = [System.IO.File]::Open($SourceAab, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $dstStream = [System.IO.File]::Open($tmpAab, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $src = New-Object System.IO.Compression.ZipArchive($srcStream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
            try {
                $dst = New-Object System.IO.Compression.ZipArchive($dstStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
                try {
                    $copied = 0
                    foreach ($entry in $src.Entries) {
                        if (Test-ShouldSkip $entry.FullName $manifestName) {
                            continue
                        }

                        $entryName = Normalize-ZipPath $entry.FullName
                        $stored = Get-IsStoredEntry $entry
                        $level = [System.IO.Compression.CompressionLevel]::Fastest
                        $methodValue = $null
                        $methodField = Get-CompressionMethodField $entry
                        if ($methodField) {
                            try { $methodValue = [int]$methodField.GetValue($entry) } catch { }
                        }
                        if ($stored -or $methodValue -eq 0) {
                            $level = [System.IO.Compression.CompressionLevel]::NoCompression
                        }

                        $newEntry = $dst.CreateEntry($entryName, $level)
                        try { $newEntry.LastWriteTime = $entry.LastWriteTime } catch { }
                        if ($null -ne $methodValue) {
                            Set-EntryCompressionMethod $newEntry $methodValue
                        } elseif ($stored) {
                            Set-EntryCompressionMethod $newEntry 0
                        }

                        if ([string]::IsNullOrEmpty($entry.Name) -or $entryName.EndsWith("/")) {
                            $copied++
                            continue
                        }

                        $inStream = $entry.Open()
                        try {
                            $outStream = $newEntry.Open()
                            try {
                                $inStream.CopyTo($outStream)
                            } finally {
                                $outStream.Dispose()
                            }
                        } finally {
                            $inStream.Dispose()
                        }

                        $copied++
                        if (($copied % 500) -eq 0) {
                            Write-Host "[INFO] Copied $copied entries..."
                        }
                    }

                    # Use Deflate, not STORED. .NET ZipArchive NoCompression still writes a
                    # Deflate wrapper, so forcing method 0 makes compressed_size > uncompressed
                    # and jarsigner fails with "attempt to write past end of STORED entry".
                    $manEntry = $dst.CreateEntry($manifestName, [System.IO.Compression.CompressionLevel]::Fastest)
                    $manIn = [System.IO.File]::OpenRead($ManifestPath)
                    try {
                        $manOut = $manEntry.Open()
                        try {
                            $manIn.CopyTo($manOut)
                        } finally {
                            $manOut.Dispose()
                        }
                    } finally {
                        $manIn.Dispose()
                    }

                    Write-Host "[INFO] Copied $copied entries and added $manifestName"
                } finally {
                    $dst.Dispose()
                }
            } finally {
                $src.Dispose()
            }
        } finally {
            $dstStream.Dispose()
        }
    } finally {
        $srcStream.Dispose()
    }

    if (Test-Path -LiteralPath $DestAab) {
        Remove-Item -LiteralPath $DestAab -Force
    }
    Move-Item -LiteralPath $tmpAab -Destination $DestAab
    Write-Host "[INFO] Wrote $DestAab"
    exit 0
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace
    }
    $tmpAab = "$DestAab.rewriting"
    if (Test-Path -LiteralPath $tmpAab) {
        Remove-Item -LiteralPath $tmpAab -Force -ErrorAction SilentlyContinue
    }
    exit 1
}
