<#
Folder Clear - pick a folder, preview it, move its files out into a holding folder (nothing is deleted).
Windows PowerShell 5.1 + WPF. Run it with Start-FolderClear.cmd.

Safety rules (all enforced in code, see Test-TargetFolder, Get-CleanPlan, Invoke-Clean):
  * Only files directly inside the chosen folder. Subfolders are never entered.
  * Files are MOVED (same-drive rename, no copy, no overwrite) into a holding folder and can be put back.
    There is no delete code in this program. Disk space is NOT freed.
  * Hidden files, system files and links are skipped.
  * Drive roots, Windows, Program Files, user profile folders and similar are refused.
  * Network, removable and linked/junction folders are refused.
  * Nothing happens until you press the button and confirm.
#>
[CmdletBinding()]
param(
    [switch]$NoUI,
    [switch]$Screenshot,
    [string]$DemoFolder,
    [string]$ScreenshotDir = (Join-Path $PSScriptRoot 'docs\screenshots')
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- core logic

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Test-IsLink {
    param($Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-ProtectedPaths {
    $sd = $env:SystemDrive
    if (-not $sd) { $sd = 'C:' }
    # The folder itself and everything under it is refused.
    $trees = @(
        $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432,
        $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA,
        "$sd\Recovery", "$sd\System Volume Information", "$sd\`$Recycle.Bin", "$sd\Boot"
    )
    # Only the folder itself (and any folder that contains it) is refused.
    $exact = @(
        $env:USERPROFILE, "$sd\Users",
        [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('MyPictures'), [Environment]::GetFolderPath('MyMusic'),
        [Environment]::GetFolderPath('MyVideos'),
        $env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial
    )
    $clean = { param($list) @($list | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique) }
    return [pscustomobject]@{ Trees = (& $clean $trees); Exact = (& $clean $exact) }
}

function Test-TargetFolder {
    param([string]$Path)
    $r = [pscustomobject]@{ Ok = $false; Path = $null; Reason = '' }
    if ([string]::IsNullOrWhiteSpace($Path)) { $r.Reason = 'No folder selected yet.'; return $r }
    $Path = $Path.Trim().Trim('"')
    if ($Path.StartsWith('\\')) { $r.Reason = 'Network and device paths are not supported.'; return $r }
    if ($Path -notmatch '^[A-Za-z]:\\') { $r.Reason = 'Use a full path such as C:\Users\you\Downloads\Old stuff'; return $r }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { $r.Reason = 'That path is not valid.'; return $r }
    if ($full -match '^[A-Za-z]:$') { $r.Reason = 'A whole drive cannot be cleaned. Pick a folder on it.'; return $r }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { $r.Reason = 'That folder does not exist.'; return $r }

    try {
        $drive = New-Object System.IO.DriveInfo($full.Substring(0, 1))
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
            $r.Reason = 'Only folders on a built-in drive are supported.'
            return $r
        }
    } catch { $r.Reason = 'Could not check which drive that folder is on.'; return $r }

    # No link or junction anywhere in the path.
    $cur = $full
    while ($cur -and $cur -notmatch '^[A-Za-z]:$') {
        $di = New-Object System.IO.DirectoryInfo($cur)
        if (Test-IsLink $di) { $r.Reason = 'Folders reached through a link or junction are refused.'; return $r }
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if (-not $parent) { break }
        $cur = $parent.TrimEnd('\')
    }
    $selfInfo = New-Object System.IO.DirectoryInfo($full)
    if (($selfInfo.Attributes -band [System.IO.FileAttributes]::System) -ne 0) {
        $r.Reason = 'System folders are refused.'; return $r
    }

    if (Test-InsideHolding $full) { $r.Reason = 'This is the holding folder where moved files are kept. Pick another folder.'; return $r }
    $p = Get-ProtectedPaths
    foreach ($t in $p.Trees) {
        if ([string]::Equals($full, $t, 'OrdinalIgnoreCase') -or $full.StartsWith($t + '\', 'OrdinalIgnoreCase') -or $t.StartsWith($full + '\', 'OrdinalIgnoreCase')) {
            $r.Reason = 'This is a protected Windows or app folder.'; return $r
        }
    }
    foreach ($t in $p.Exact) {
        if ([string]::Equals($full, $t, 'OrdinalIgnoreCase') -or $t.StartsWith($full + '\', 'OrdinalIgnoreCase')) {
            $r.Reason = 'This is a personal root folder. Pick a folder inside it instead.'; return $r
        }
    }
    $r.Ok = $true
    $r.Path = $full
    return $r
}

# Moves one file with the Windows MoveFileEx call and NO flags: it never overwrites, and it never
# falls back to copy-then-delete across drives. It either renames the file or fails. Returns 0 on success,
# otherwise the Windows error code. There is no delete call anywhere in this program.
if (-not ('FcNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FcNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileExW(string from, string to, uint flags);
    public static int MoveSameVolume(string from, string to) {
        return MoveFileExW(from, to, 0) ? 0 : Marshal.GetLastWin32Error();
    }
}
'@
}

$script:HoldingName = 'Folder Clear Holding'

# Where moved files are kept: on the same drive as the chosen folder, so the move is an instant rename.
# On the drive that holds your Windows profile it is inside your profile folder (always writable for you).
# On any other built-in drive it is a folder at the top of that drive.
function Get-HoldingRoot {
    param([string]$DriveLetter)
    $profileDrive = ([string]$env:USERPROFILE).Substring(0, 1)
    if ($DriveLetter -ieq $profileDrive) { return (Join-Path $env:USERPROFILE $script:HoldingName) }
    return ($DriveLetter.ToUpper() + ':\' + $script:HoldingName)
}

function Test-InsideHolding {
    param([string]$Full)
    return ($Full -match ('(^|\\)' + [regex]::Escape($script:HoldingName) + '(\\|$)'))
}

# True when nothing from the drive root down to this folder is a link or junction.
function Test-PathHasNoLink {
    param([string]$Full)
    $cur = $Full.TrimEnd('\')
    while ($cur -and $cur -notmatch '^[A-Za-z]:$') {
        if (Test-Path -LiteralPath $cur) {
            $di = New-Object System.IO.DirectoryInfo($cur)
            if (Test-IsLink $di) { return $false }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if (-not $parent) { break }
        $cur = $parent.TrimEnd('\')
    }
    return $true
}

function Get-CleanPlan {
    param([string]$Path, [string]$HoldingRoot)
    $check = Test-TargetFolder -Path $Path
    $plan = [pscustomobject]@{
        Ok = $check.Ok; Reason = $check.Reason; Path = $check.Path
        Files = @(); Bytes = [long]0; Subfolders = 0
        SkippedHiddenSystem = 0; SkippedLinks = 0
        Drive = ''; HoldingRoot = ''
    }
    if (-not $check.Ok) { return $plan }
    $plan.Drive = $check.Path.Substring(0, 1).ToUpper()
    if (-not $HoldingRoot) { $HoldingRoot = Get-HoldingRoot -DriveLetter $plan.Drive }
    $plan.HoldingRoot = $HoldingRoot
    $rootFull = $null
    try { $rootFull = [System.IO.Path]::GetFullPath($HoldingRoot).TrimEnd('\') } catch { }
    if (-not $rootFull -or ($rootFull.Substring(0, 1) -ine $plan.Drive)) {
        $plan.Ok = $false; $plan.Reason = 'The holding folder would not be on the same drive as this folder, so nothing can be moved safely.'
        return $plan
    }
    if (-not (Test-PathHasNoLink $rootFull)) {
        $plan.Ok = $false; $plan.Reason = 'The holding folder is reached through a link, so nothing can be moved safely.'
        return $plan
    }
    if ($check.Path.StartsWith($rootFull + '\', 'OrdinalIgnoreCase') -or [string]::Equals($check.Path, $rootFull, 'OrdinalIgnoreCase')) {
        $plan.Ok = $false; $plan.Reason = 'This is the holding folder where moved files are kept. Pick another folder.'
        return $plan
    }
    $hiddenSystem = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    try { $entries = @(Get-ChildItem -LiteralPath $check.Path -Force -ErrorAction Stop) }
    catch { $plan.Ok = $false; $plan.Reason = 'That folder could not be read.'; return $plan }
    $files = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        if ($e.PSIsContainer) { $plan.Subfolders++; continue }
        if (Test-IsLink $e) { $plan.SkippedLinks++; continue }
        if (($e.Attributes -band $hiddenSystem) -ne 0) { $plan.SkippedHiddenSystem++; continue }
        [void]$files.Add([pscustomobject]@{ Name = $e.Name; FullName = $e.FullName; Length = [long]$e.Length })
        $plan.Bytes += [long]$e.Length
    }
    $plan.Files = $files.ToArray()
    return $plan
}

function Write-Manifest {
    param([string]$BatchDir, $Manifest)
    $json = $Manifest | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $BatchDir 'manifest.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Moves each planned file into a new dated folder inside the holding folder. Nothing is copied, overwritten
# or deleted. Each file is re-checked right before it moves. A manifest listing every file is written BEFORE the
# first move, so the files can always be put back, even if the program or the PC stops half way.
function Invoke-Clean {
    param($Plan, [scriptblock]$OnProgress, [string]$BatchName)
    $result = [pscustomobject]@{ Moved = 0; Left = (New-Object System.Collections.ArrayList); Stopped = $false; StopReason = ''; BatchDir = $null }
    if (-not $Plan.Ok) { return $result }
    $stop = { param($why) $result.Stopped = $true; $result.StopReason = $why; return $result }
    $recheck = Test-TargetFolder -Path $Plan.Path
    if (-not $recheck.Ok) { return (& $stop 'The folder is no longer safe to use. Nothing was moved.') }
    $root = [System.IO.Path]::GetFullPath($Plan.HoldingRoot).TrimEnd('\')
    if ($root.Substring(0, 1) -ine $Plan.Path.Substring(0, 1)) { return (& $stop 'The holding folder is on a different drive. Nothing was moved.') }
    if (-not (Test-PathHasNoLink $root)) { return (& $stop 'The holding folder is reached through a link. Nothing was moved.') }
    if (-not $BatchName) { $BatchName = (Get-Date -Format 'yyyy-MM-dd HH-mm-ss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6) }
    $batchDir = Join-Path $root $BatchName
    try {
        [void](New-Item -ItemType Directory -Path $batchDir -ErrorAction Stop)
        if (-not (Test-PathHasNoLink $batchDir)) { throw 'link' }
    } catch { return (& $stop 'Could not create the holding folder. Nothing was moved.') }
    $result.BatchDir = $batchDir
    $manifest = [ordered]@{
        Version = 1; Created = (Get-Date).ToString('s'); SourceFolder = $Plan.Path
        Files = @($Plan.Files | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; Status = 'planned' } })
    }
    try {
        Write-Manifest -BatchDir $batchDir -Manifest $manifest
        $note = "Files moved here by Folder Clear from:`r`n$($Plan.Path)`r`n`r`nNothing was deleted. Open Folder Clear and press 'Put back last move' to return them,`r`nor copy them out yourself. You can delete this folder when you are sure you do not need the files."
        [System.IO.File]::WriteAllText((Join-Path $batchDir 'READ ME.txt'), $note)
    } catch { return (& $stop 'Could not write the list of files that are about to move, so nothing was moved.') }
    $hiddenSystem = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    $i = 0
    foreach ($f in $Plan.Files) {
        $i++
        $done = $false
        try {
            $srcDir = Get-Item -LiteralPath $Plan.Path -Force -ErrorAction Stop
            $item = Get-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $sameFolder = ($item.DirectoryName -and [string]::Equals($item.DirectoryName.TrimEnd('\'), $Plan.Path, 'OrdinalIgnoreCase'))
            $ok = (-not (Test-IsLink $srcDir)) -and (-not $item.PSIsContainer) -and $sameFolder -and (-not (Test-IsLink $item)) -and (($item.Attributes -band $hiddenSystem) -eq 0)
            $dest = Join-Path $batchDir $f.Name
            if ($ok -and -not (Test-Path -LiteralPath $dest)) {
                $rc = [FcNative]::MoveSameVolume($f.FullName, $dest)
                if ($rc -eq 0 -and (Test-Path -LiteralPath $dest) -and -not (Test-Path -LiteralPath $f.FullName)) { $done = $true }
            }
        } catch { $done = $false }
        $st = 'left'; if ($done) { $st = 'moved'; $result.Moved++ } else { [void]$result.Left.Add($f.Name) }
        $manifest.Files[$i - 1].Status = $st
        if ($OnProgress) { & $OnProgress $i $Plan.Files.Count }
    }
    try { Write-Manifest -BatchDir $batchDir -Manifest $manifest } catch { }
    return $result
}

# Batches in the holding folder that still have files in them, newest first.
function Get-HeldBatches {
    param([string]$HoldingRoot)
    $out = @()
    try {
        if (-not (Test-Path -LiteralPath $HoldingRoot -PathType Container)) { return @() }
        foreach ($d in (Get-ChildItem -LiteralPath $HoldingRoot -Directory -Force -ErrorAction Stop | Sort-Object Name -Descending)) {
            if (Test-IsLink $d) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'manifest.json'))) { continue }
            $n = @(Get-ChildItem -LiteralPath $d.FullName -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'manifest.json' -and $_.Name -ne 'READ ME.txt' }).Count
            if ($n -gt 0) { $out += [pscustomobject]@{ Dir = $d.FullName; Count = $n } }
        }
    } catch { }
    return $out
}

# Puts the files of one batch back into the folder they came from. A name that is already taken there is
# never overwritten: that file simply stays in the holding folder.
function Restore-Batch {
    param([string]$BatchDir, [string]$HoldingRoot, [scriptblock]$OnProgress)
    $res = [pscustomobject]@{ Restored = 0; Left = (New-Object System.Collections.ArrayList); Error = ''; Source = '' }
    try {
        $root = [System.IO.Path]::GetFullPath($HoldingRoot).TrimEnd('\')
        $dirFull = [System.IO.Path]::GetFullPath($BatchDir).TrimEnd('\')
        if (-not $dirFull.StartsWith($root + '\', 'OrdinalIgnoreCase')) { $res.Error = 'That batch is not inside the holding folder.'; return $res }
        if (-not (Test-PathHasNoLink $dirFull)) { $res.Error = 'The holding folder is reached through a link.'; return $res }
        $mf = Get-Content -LiteralPath (Join-Path $dirFull 'manifest.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        $src = Test-TargetFolder -Path ([string]$mf.SourceFolder)
        if (-not $src.Ok) { $res.Error = "The original folder cannot be used any more ($($src.Reason)) The files are still safe in: $dirFull"; return $res }
        if ($src.Path.Substring(0, 1) -ine $dirFull.Substring(0, 1)) { $res.Error = 'The original folder is on a different drive.'; return $res }
        $res.Source = $src.Path
        $names = @($mf.Files | ForEach-Object { [string]$_.Name })
        $i = 0
        foreach ($n in $names) {
            $i++
            $held = Join-Path $dirFull $n
            $ok = ($n -and ([System.IO.Path]::GetFileName($n) -eq $n)) -and (Test-Path -LiteralPath $held -PathType Leaf)
            if (-not $ok) { if ($OnProgress) { & $OnProgress $i $names.Count }; continue }
            $item = Get-Item -LiteralPath $held -Force
            $dest = Join-Path $src.Path $n
            $done = $false
            if (-not (Test-IsLink $item) -and -not (Test-Path -LiteralPath $dest)) {
                $rc = [FcNative]::MoveSameVolume($held, $dest)
                if ($rc -eq 0 -and (Test-Path -LiteralPath $dest) -and -not (Test-Path -LiteralPath $held)) { $done = $true }
            }
            if ($done) { $res.Restored++ } else { [void]$res.Left.Add($n) }
            if ($OnProgress) { & $OnProgress $i $names.Count }
        }
    } catch { $res.Error = 'Could not read this batch. The files are still in the holding folder.' }
    return $res
}

if ($NoUI) { return }

# ------------------------------------------------------------------------ UI

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Folder Clear" Width="760" Height="790" MinWidth="640" MinHeight="700"
        WindowStartupLocation="CenterScreen" Background="#0B1220" FontFamily="Segoe UI"
        AllowDrop="True" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E6EDF7"/>
      <Setter Property="Background" Value="#1E2A44"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#1A2338"/>
                <Setter Property="Foreground" Value="#7C89A6"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#E11D48"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Padding" Value="18,13"/>
    </Style>
    <Style x:Key="Row" TargetType="ListBoxItem">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="rb" Padding="12,7" Background="Transparent" CornerRadius="6">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="rb" Property="Background" Value="#1A2640"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Background="#0B1220" Margin="0">
    <Grid Margin="28,24,28,22">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Margin="0,0,0,18">
        <TextBlock Text="Folder Clear" FontSize="30" FontWeight="Bold" Foreground="#F1F5FB"/>
        <TextBlock Text="Clear a folder. Put files back when needed."
                   FontSize="14" Foreground="#9FB0CE" Margin="0,4,0,0" TextWrapping="Wrap"/>
      </StackPanel>

      <Border Grid.Row="1" Background="#131C2F" CornerRadius="14" Padding="18" Margin="0,0,0,14" BorderBrush="#1F2C47" BorderThickness="1">
        <StackPanel>
          <TextBlock Text="1  FOLDER  (or drop a folder on this window)" FontSize="12" FontWeight="SemiBold" Foreground="#2DD4BF"/>
          <Grid Margin="0,10,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBox x:Name="PathBox" Grid.Column="0" FontSize="14" Padding="12,10" Background="#0E1627" Foreground="#F1F5FB"
                     CaretBrush="#F1F5FB" BorderBrush="#2A3A5C" VerticalContentAlignment="Center"
                     ToolTip="Type or paste a folder path and press Enter, or drop a folder on this window."/>
            <Button x:Name="BrowseBtn" Grid.Column="1" Content="Browse..." Style="{StaticResource Btn}" Margin="10,0,0,0"/>
          </Grid>
        </StackPanel>
      </Border>

      <Border Grid.Row="2" x:Name="Banner" Background="#2A1A22" CornerRadius="10" Padding="14,10" Margin="0,0,0,14" Visibility="Collapsed">
        <TextBlock x:Name="BannerText" FontSize="13.5" Foreground="#FFD4DC" TextWrapping="Wrap"/>
      </Border>

      <Border Grid.Row="3" Background="#131C2F" CornerRadius="14" Padding="18" BorderBrush="#1F2C47" BorderThickness="1">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="2  PREVIEW" FontSize="12" FontWeight="SemiBold" Foreground="#2DD4BF"/>
          <UniformGrid Grid.Row="1" Rows="1" Columns="4" Margin="0,12,0,12">
            <Border Background="#0E1627" CornerRadius="10" Padding="12,10" Margin="0,0,8,0">
              <StackPanel><TextBlock x:Name="StatFiles" Text="-" FontSize="24" FontWeight="Bold" Foreground="#F1F5FB"/>
              <TextBlock Text="files to move" FontSize="12" Foreground="#9FB0CE"/></StackPanel></Border>
            <Border Background="#0E1627" CornerRadius="10" Padding="12,10" Margin="0,0,8,0">
              <StackPanel><TextBlock x:Name="StatSize" Text="-" FontSize="24" FontWeight="Bold" Foreground="#F1F5FB"/>
              <TextBlock Text="total size" FontSize="12" Foreground="#9FB0CE"/></StackPanel></Border>
            <Border Background="#0E1627" CornerRadius="10" Padding="12,10" Margin="0,0,8,0">
              <StackPanel><TextBlock x:Name="StatFolders" Text="-" FontSize="24" FontWeight="Bold" Foreground="#5EEAD4"/>
              <TextBlock Text="subfolders kept" FontSize="12" Foreground="#9FB0CE"/></StackPanel></Border>
            <Border Background="#0E1627" CornerRadius="10" Padding="12,10">
              <StackPanel><TextBlock x:Name="StatSkipped" Text="-" FontSize="24" FontWeight="Bold" Foreground="#FBBF24"/>
              <TextBlock Text="files skipped" FontSize="12" Foreground="#9FB0CE"/></StackPanel></Border>
          </UniformGrid>
          <Grid Grid.Row="2">
            <ListBox x:Name="FileList" Background="#0E1627" BorderThickness="0" Foreground="#E6EDF7"
                     ItemContainerStyle="{StaticResource Row}" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
              <ListBox.ItemTemplate>
                <DataTemplate>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="{Binding Name}" FontSize="13.5" Foreground="#E6EDF7" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Grid.Column="1" Text="{Binding SizeText}" FontSize="13" Foreground="#9FB0CE" Margin="12,0,0,0"/>
                  </Grid>
                </DataTemplate>
              </ListBox.ItemTemplate>
            </ListBox>
            <TextBlock x:Name="EmptyHint" Text="Choose a folder to see which files would be moved."
                       Foreground="#8A9BBA" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False"/>
          </Grid>
        </Grid>
      </Border>

      <StackPanel Grid.Row="4" Margin="2,12,2,12">
        <TextBlock x:Name="BinInfo" FontSize="12.5" FontWeight="SemiBold" Foreground="#5EEAD4" TextWrapping="Wrap" Margin="0,0,0,4"/>
        <TextBlock FontSize="12.5" Foreground="#9FB0CE" TextWrapping="Wrap"
                   Text="Nothing is deleted and no disk space is freed. Only files directly inside this folder are moved, into the holding folder on the same drive. Subfolders, hidden, system and linked files stay. Press Put back last move to return them. You delete the held files yourself when you are sure."/>
      </StackPanel>

      <Grid Grid.Row="5">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Button x:Name="CleanBtn" Grid.Row="0" Content="Move files to the holding folder" Style="{StaticResource Danger}" IsEnabled="False"/>
        <ProgressBar x:Name="Progress" Grid.Row="1" Height="6" Margin="0,10,0,0" Minimum="0" Maximum="100" Value="0"
                     Background="#1A2338" Foreground="#2DD4BF" BorderThickness="0" Visibility="Hidden"/>
        <Grid Grid.Row="2" Margin="0,10,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Button x:Name="RestoreBtn" Grid.Column="0" Content="Put files back" Style="{StaticResource Btn}" Height="40" IsEnabled="False"/>
          <Button x:Name="OpenBtn" Grid.Column="2" Content="Open holding folder" Style="{StaticResource Btn}" Height="40"/>
        </Grid>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($n in 'PathBox','BrowseBtn','Banner','BannerText','StatFiles','StatSize','StatFolders','StatSkipped','FileList','EmptyHint','CleanBtn','Progress','BinInfo','RestoreBtn','OpenBtn') {
    $ui[$n] = $window.FindName($n)
}
$script:Plan = $null

function Update-Ui { $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) }

function Show-Banner {
    param([string]$Text, [string]$Kind = 'warn')
    $palette = @{
        warn = @('#2A1A22', '#FFD4DC'); info = @('#10302D', '#C9FBF3'); caution = @('#33270F', '#FDE9B0')
    }
    $c = $palette[$Kind]
    $conv = New-Object System.Windows.Media.BrushConverter
    $ui.Banner.Background = $conv.ConvertFromString($c[0])
    $ui.BannerText.Foreground = $conv.ConvertFromString($c[1])
    $ui.BannerText.Text = $Text
    $ui.Banner.Visibility = 'Visible'
}

$script:RestoreRoot = $null
function Update-RestoreButton {
    param($Plan)
    $root = $null
    if ($Plan -and $Plan.PSObject.Properties['HoldingRoot'] -and $Plan.HoldingRoot) { $root = $Plan.HoldingRoot }
    elseif ($script:RestoreRoot) { $root = $script:RestoreRoot }
    $script:RestoreRoot = $root
    $last = $null
    if ($root) { $last = @(Get-HeldBatches -HoldingRoot $root) | Select-Object -First 1 }
    $ui.RestoreBtn.IsEnabled = [bool]$last
    if ($last) {
        $word = 'files'; if ($last.Count -eq 1) { $word = 'file' }
        $ui.RestoreBtn.Content = "Put back last move ($($last.Count) $word)"
    } else { $ui.RestoreBtn.Content = 'Put files back' }
}

function Show-Plan {
    param($Plan)
    $script:Plan = $Plan
    $ui.FileList.Items.Clear()
    $ui.BinInfo.Text = ''
    if ($Plan.Ok -and $Plan.HoldingRoot) {
        $ui.BinInfo.Text = ('Files will be moved to: {0}   (same drive, no disk space freed)' -f $Plan.HoldingRoot)
    }
    Update-RestoreButton $Plan
    if (-not $Plan.Ok) {
        foreach ($n in 'StatFiles','StatSize','StatFolders','StatSkipped') { $ui[$n].Text = '-' }
        $ui.CleanBtn.IsEnabled = $false
        $ui.CleanBtn.Content = 'Move files to the holding folder'
        $ui.EmptyHint.Visibility = 'Visible'
        $ui.EmptyHint.Text = 'Nothing to preview.'
        if ($Plan.Reason -and $Plan.Reason -ne 'No folder selected yet.') { Show-Banner $Plan.Reason 'warn' } else { $ui.Banner.Visibility = 'Collapsed' }
        return
    }
    $count = $Plan.Files.Count
    $skipped = $Plan.SkippedHiddenSystem + $Plan.SkippedLinks + $Plan.SkippedLarge
    $ui.StatFiles.Text = "$count"
    $ui.StatSize.Text = (Format-Size $Plan.Bytes)
    $ui.StatFolders.Text = "$($Plan.Subfolders)"
    $ui.StatSkipped.Text = "$skipped"
    $max = 300
    foreach ($f in ($Plan.Files | Select-Object -First $max)) {
        [void]$ui.FileList.Items.Add([pscustomobject]@{ Name = $f.Name; SizeText = (Format-Size $f.Length) })
    }
    if ($count -gt $max) {
        [void]$ui.FileList.Items.Add([pscustomobject]@{ Name = "... and $($count - $max) more files"; SizeText = '' })
    }
    if ($count -eq 0) {
        $ui.EmptyHint.Visibility = 'Visible'; $ui.EmptyHint.Text = 'No files directly inside this folder.'
        $ui.CleanBtn.IsEnabled = $false; $ui.CleanBtn.Content = 'Nothing to move'
    } else {
        $ui.EmptyHint.Visibility = 'Collapsed'
        $ui.CleanBtn.IsEnabled = $true
        $word = 'files'; if ($count -eq 1) { $word = 'file' }
        $ui.CleanBtn.Content = "Move $count $word to the holding folder"
    }
    $notes = @()
    if ($Plan.SkippedHiddenSystem -gt 0) { $notes += "$($Plan.SkippedHiddenSystem) hidden or system" }
    if ($Plan.SkippedLinks -gt 0) { $notes += "$($Plan.SkippedLinks) link" }
    if ($notes.Count -gt 0) { Show-Banner ('Skipped and left in place: ' + ($notes -join ', ') + '.') 'caution' }
    else { $ui.Banner.Visibility = 'Collapsed' }
}

function Start-Restore {
    param([switch]$SkipConfirm)
    if (-not $script:RestoreRoot) { return }
    $batches = @(Get-HeldBatches -HoldingRoot $script:RestoreRoot)
    if ($batches.Count -eq 0) { Update-RestoreButton $null; return }
    $b = $batches[0]
    if (-not $SkipConfirm) {
        $answer = [System.Windows.MessageBox]::Show($window, "Put the $($b.Count) held file(s) from the most recent move back where they came from?`n`nA file is never overwritten: if a file with the same name is already there, it stays in the holding folder.", 'Put files back', 'YesNo', 'Question', 'Yes')
        if ($answer -ne 'Yes') { return }
    }
    $r = Restore-Batch -BatchDir $b.Dir -HoldingRoot $script:RestoreRoot
    if ($ui.PathBox.Text) { Show-Plan (Get-CleanPlan -Path $ui.PathBox.Text) }
    if ($r.Error) { Show-Banner $r.Error 'warn' }
    elseif ($r.Left.Count -eq 0) { Show-Banner "Put $($r.Restored) file(s) back into $($r.Source)." 'info' }
    else { Show-Banner "Put $($r.Restored) file(s) back. $($r.Left.Count) stayed in the holding folder because the name is already used (or the file was in use)." 'caution' }
}

function Set-Folder {
    param([string]$Path)
    $ui.PathBox.Text = $Path
    $ui.Progress.Visibility = 'Hidden'
    Show-Plan (Get-CleanPlan -Path $Path)
}

function Start-Clean {
    param([switch]$SkipConfirm)
    $plan = $script:Plan
    if (-not $plan -or -not $plan.Ok -or $plan.Files.Count -eq 0) { return }
    if (-not $SkipConfirm) {
        $msg = "Move $($plan.Files.Count) file(s) ($(Format-Size $plan.Bytes)) from:`n`n$($plan.Path)`n`ninto the holding folder:`n$($plan.HoldingRoot)`n`nNothing is deleted and no disk space is freed. Subfolders are not touched. You can press Put back last move to return them."
        $answer = [System.Windows.MessageBox]::Show($window, $msg, 'Confirm', 'YesNo', 'Warning', 'No')
        if ($answer -ne 'Yes') { return }
    }
    # The folder may have changed since the preview. If so, stop and show the new preview.
    $fresh = Get-CleanPlan -Path $plan.Path
    $same = $fresh.Ok -and ($fresh.Files.Count -eq $plan.Files.Count) -and (-not (Compare-Object @($fresh.Files.FullName) @($plan.Files.FullName)))
    if (-not $same) {
        Show-Plan $fresh
        Show-Banner 'The folder changed after the preview. Nothing was moved. Check the new preview and try again.' 'caution'
        return
    }
    $ui.CleanBtn.IsEnabled = $false
    $ui.BrowseBtn.IsEnabled = $false
    $ui.Progress.Value = 0
    $ui.Progress.Visibility = 'Visible'
    Update-Ui
    $result = Invoke-Clean -Plan $plan -OnProgress {
        param($i, $n)
        if (($i % 5 -eq 0) -or ($i -eq $n)) { $ui.Progress.Value = [math]::Round(100 * $i / $n); Update-Ui }
    }
    $ui.BrowseBtn.IsEnabled = $true
    Show-Plan (Get-CleanPlan -Path $plan.Path)
    $ui.Progress.Visibility = 'Visible'
    $ui.Progress.Value = 100
    $left = $result.Left.Count
    if ($result.Stopped) { Show-Banner "$($result.StopReason)" 'caution' }
    elseif ($left -eq 0) { Show-Banner "Done. $($result.Moved) file(s) moved to the holding folder. Nothing was deleted. Press Put back last move to return them." 'info' }
    else { Show-Banner "Moved $($result.Moved) file(s). $left file(s) stayed where they were (in use, or the name was already taken in the holding folder). Nothing was deleted." 'caution' }
    Update-RestoreButton $plan
}

function Save-WindowPng {
    param([string]$File)
    Update-Ui
    $root = $window.Content
    $w = [int]$root.ActualWidth; $h = [int]$root.ActualHeight
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $dir = Split-Path -Parent $File
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $fs = [System.IO.File]::Create($File)
    try { $enc.Save($fs) } finally { $fs.Close() }
}

$ui.BrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the folder whose files you want to move into the holding folder'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Set-Folder $dlg.SelectedPath }
})
$ui.PathBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Set-Folder $ui.PathBox.Text } })
$ui.CleanBtn.Add_Click({ Start-Clean })
$ui.OpenBtn.Add_Click({
    $root = $script:RestoreRoot
    if (-not $root) { $root = Get-HoldingRoot -DriveLetter ([string]$env:SystemDrive).Substring(0, 1) }
    if (Test-Path -LiteralPath $root -PathType Container) { Start-Process explorer.exe -ArgumentList ('"' + $root + '"') }
    else { Show-Banner 'Nothing has been moved yet, so the holding folder does not exist.' 'caution' }
})
$ui.RestoreBtn.Add_Click({ Start-Restore })
$window.Add_DragOver({ param($s, $e) $e.Effects = [System.Windows.DragDropEffects]::Link; $e.Handled = $true })
$window.Add_Drop({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        Set-Folder (@($e.Data.GetData([System.Windows.DataFormats]::FileDrop))[0])
    }
})

if ($Screenshot) {
    if (-not $DemoFolder) { throw 'Screenshot mode needs -DemoFolder (a folder of throwaway files).' }
    $window.ShowActivated = $false
    $window.Show()
    Save-WindowPng (Join-Path $ScreenshotDir '1-start.png')
    Set-Folder $DemoFolder
    Save-WindowPng (Join-Path $ScreenshotDir '2-preview.png')
    Start-Clean -SkipConfirm
    Save-WindowPng (Join-Path $ScreenshotDir '3-done.png')
    Start-Restore -SkipConfirm
    Save-WindowPng (Join-Path $ScreenshotDir '5-restored.png')
    Set-Folder $env:SystemRoot
    Save-WindowPng (Join-Path $ScreenshotDir '4-refused.png')
    $window.Close()
    return
}

Show-Plan (Get-CleanPlan -Path '')
[void]$window.ShowDialog()
