#requires -Version 5.1
<#
.SYNOPSIS
    Packs src/ into a drag-and-droppable BetterNotifications.rbxmx.

.DESCRIPTION
    Rojo is the better tool if you already have it (`rojo build -o
    BetterNotifications.rbxm`). This exists so the module can be built and
    handed to someone with nothing installed but Windows.

    Naming follows Rojo's conventions:
        Foo.luau            -> ModuleScript "Foo"
        Foo.client.luau     -> LocalScript  "Foo"
        Foo.server.luau     -> Script       "Foo"
        dir/init.luau       -> ModuleScript named after the directory
        dir/ (no init)      -> Folder

.EXAMPLE
    .\build-rbxmx.ps1
    .\build-rbxmx.ps1 -Output C:\temp\BetterNotifications.rbxmx
#>
[CmdletBinding()]
param(
    [string]$Source = (Join-Path $PSScriptRoot 'src'),
    [string]$Output = (Join-Path $PSScriptRoot 'BetterNotifications.rbxmx'),
    [string]$Name = 'BetterNotifications'
)

$ErrorActionPreference = 'Stop'

# A single file is valid too, so a one-off script can be packed on its own:
#   .\build-rbxmx.ps1 -Source test\Foo.server.luau -Output Foo.rbxmx -Name Foo
if (-not (Test-Path $Source)) {
    throw "Source not found: $Source"
}

$script:ReferentCounter = 0
function New-Referent {
    $value = "RBX$($script:ReferentCounter)"
    $script:ReferentCounter++
    return $value
}

function ConvertTo-XmlText {
    param([string]$Text)
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function ConvertTo-CdataText {
    param([string]$Text)
    # A literal ]]> would terminate the CDATA section early. Luau long-bracket
    # comments make ]] common, so this is not merely theoretical.
    return $Text.Replace(']]>', ']]]]><![CDATA[>')
}

function Get-InstanceName {
    param([string]$FileName)
    foreach ($suffix in @('.client.luau', '.server.luau', '.luau', '.lua')) {
        if ($FileName.EndsWith($suffix)) {
            return $FileName.Substring(0, $FileName.Length - $suffix.Length)
        }
    }
    return $FileName
}

function Get-ClassForFile {
    param([string]$FileName)
    if ($FileName -like '*.client.luau' -or $FileName -like '*.client.lua') { return 'LocalScript' }
    if ($FileName -like '*.server.luau' -or $FileName -like '*.server.lua') { return 'Script' }
    return 'ModuleScript'
}

function Write-Instance {
    param(
        [System.Text.StringBuilder]$Builder,
        [string]$Path,
        [string]$InstanceName,
        [int]$Depth
    )

    $pad = ' ' * (($Depth + 1) * 2)
    $isDirectory = Test-Path $Path -PathType Container

    $class = 'Folder'
    $sourceFile = $null
    $children = @()

    if ($isDirectory) {
        $initCandidates = @(
            @{ File = 'init.luau'; Class = 'ModuleScript' },
            @{ File = 'init.lua'; Class = 'ModuleScript' },
            @{ File = 'init.server.luau'; Class = 'Script' },
            @{ File = 'init.client.luau'; Class = 'LocalScript' }
        )

        $initName = $null
        foreach ($candidate in $initCandidates) {
            $candidatePath = Join-Path $Path $candidate.File
            if (Test-Path $candidatePath -PathType Leaf) {
                $class = $candidate.Class
                $sourceFile = $candidatePath
                $initName = $candidate.File
                break
            }
        }

        foreach ($child in Get-ChildItem -Path $Path | Sort-Object { $_.PSIsContainer }, Name) {
            if ($child.PSIsContainer) {
                $children += @{ Path = $child.FullName; Name = $child.Name }
            }
            elseif ($child.Name -like '*.luau' -or $child.Name -like '*.lua') {
                if ($child.Name -ne $initName) {
                    $children += @{ Path = $child.FullName; Name = (Get-InstanceName $child.Name) }
                }
            }
        }
    }
    else {
        $class = Get-ClassForFile (Split-Path $Path -Leaf)
        $sourceFile = $Path
    }

    $referent = New-Referent
    [void]$Builder.AppendLine("$pad<Item class=`"$class`" referent=`"$referent`">")
    [void]$Builder.AppendLine("$pad  <Properties>")
    [void]$Builder.AppendLine("$pad    <string name=`"Name`">$(ConvertTo-XmlText $InstanceName)</string>")

    if ($sourceFile) {
        $code = Get-Content -Path $sourceFile -Raw -Encoding UTF8
        if ($null -eq $code) { $code = '' }
        $code = $code -replace "`r`n", "`n"
        [void]$Builder.AppendLine("$pad    <ProtectedString name=`"Source`"><![CDATA[$(ConvertTo-CdataText $code)]]></ProtectedString>")
    }

    [void]$Builder.AppendLine("$pad  </Properties>")

    foreach ($child in $children) {
        Write-Instance -Builder $Builder -Path $child.Path -InstanceName $child.Name -Depth ($Depth + 1)
    }

    [void]$Builder.AppendLine("$pad</Item>")
}

$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine('<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">')
Write-Instance -Builder $builder -Path $Source -InstanceName $Name -Depth 0
[void]$builder.AppendLine('</roblox>')

# No BOM: Studio is fine with it, but plain UTF-8 keeps diffs clean.
$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Output, $builder.ToString(), $encoding)

$instanceCount = $script:ReferentCounter
Write-Host "Wrote $Output ($instanceCount instances)."
Write-Host "Drag it into Studio, then move $Name into ServerScriptService."
