# Safety tests for Folder Clear. Uses throwaway files only, created under C:\FC-Test-<id>.
# Run on Windows PowerShell 5.1:  powershell -File tests\Test-FolderClear.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\FolderClear.ps1') -NoUI

$script:failures = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" } else { Write-Host "FAIL  $Name"; $script:failures++ }
}

$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
$root = "C:\FC-Test-$id"
$ext = "C:\FC-Test-$id-external"
New-Item -ItemType Directory -Path $root, $ext | Out-Null
Write-Host "Windows: $([Environment]::OSVersion.VersionString)"

# --- refusals -------------------------------------------------------------
$refuse = @{
    'empty'              = ''
    'drive root'         = 'C:\'
    'drive only'         = 'C:'
    'relative path'      = 'Downloads'
    'network path'       = '\\server\share\stuff'
    'Windows folder'     = $env:SystemRoot
    'System32'           = "$env:SystemRoot\System32"
    'Program Files'      = $env:ProgramFiles
    'user profile'       = $env:USERPROFILE
    'Users folder'       = "$env:SystemDrive\Users"
    'Documents folder'   = [Environment]::GetFolderPath('MyDocuments')
    'AppData'            = $env:APPDATA
    'missing folder'     = "$root\does-not-exist"
}
foreach ($k in $refuse.Keys) {
    $r = Test-TargetFolder -Path $refuse[$k]
    Assert-That (-not $r.Ok) "refuses: $k"
}

# --- links and junctions --------------------------------------------------
New-Item -ItemType Directory -Path "$ext\sub" | Out-Null
Set-Content -LiteralPath "$ext\outside.txt" -Value 'must survive'
Set-Content -LiteralPath "$ext\sub\deep.txt" -Value 'must survive'
cmd /c mklink /J "$root\JunctionToExternal" $ext | Out-Null
Assert-That (-not (Test-TargetFolder -Path "$root\JunctionToExternal").Ok) 'refuses a junction as the target'
Assert-That (-not (Test-TargetFolder -Path "$root\JunctionToExternal\sub").Ok) 'refuses a folder reached through a junction'

# --- plan ------------------------------------------------------------------
$work = "$root\work"
New-Item -ItemType Directory -Path "$work\Keep-Me" | Out-Null
$a = "fc-$id-a.txt"; $b = "fc-$id-b.log"
Set-Content -LiteralPath "$work\$a" -Value 'a'
Set-Content -LiteralPath "$work\$b" -Value 'bb'
Set-Content -LiteralPath "$work\Keep-Me\inner.txt" -Value 'inner must survive'
Set-Content -LiteralPath "$work\hidden.txt" -Value 'hidden'
(Get-Item -LiteralPath "$work\hidden.txt" -Force).Attributes = 'Hidden'
Set-Content -LiteralPath "$work\system.dat" -Value 'system'
(Get-Item -LiteralPath "$work\system.dat" -Force).Attributes = 'System,Hidden'
cmd /c mklink /J "$work\LinkedFolder" $ext | Out-Null
$symlinkMade = $false
try { New-Item -ItemType SymbolicLink -Path "$work\link.txt" -Target "$ext\outside.txt" | Out-Null; $symlinkMade = $true } catch { Write-Host 'NOTE  file symlink could not be created here; that check is skipped' }

$hold = "$root\hold"
$plan = Get-CleanPlan -Path $work -HoldingRoot $hold
Assert-That $plan.Ok 'plan is accepted for a normal folder'
Assert-That ($plan.Files.Count -eq 2) "plan lists exactly the 2 plain files (got $($plan.Files.Count))"
Assert-That ($plan.Subfolders -eq 2) "subfolders and junctions are counted as kept (got $($plan.Subfolders))"
Assert-That ($plan.SkippedHiddenSystem -eq 2) "hidden and system files are skipped (got $($plan.SkippedHiddenSystem))"
if ($symlinkMade) { Assert-That ($plan.SkippedLinks -eq 1) "file symlink is skipped (got $($plan.SkippedLinks))" }
Assert-That ($plan.HoldingRoot -eq $hold) 'the holding folder is the one given'
$defRoot = Get-HoldingRoot -DriveLetter 'C'
Write-Host "NOTE  default holding folder on C: = $defRoot"
Assert-That ($defRoot -like "$env:USERPROFILE\*" -or $env:USERPROFILE.Substring(0,1) -ne 'C') 'default holding folder is inside the profile on the profile drive'
Assert-That (-not (Test-TargetFolder -Path $defRoot).Ok) 'the holding folder cannot be chosen as the target'
$plan2 = Get-CleanPlan -Path "$hold\x" -HoldingRoot $hold
Assert-That (-not $plan2.Ok) 'a folder inside the holding folder cannot be the target'

# --- move ------------------------------------------------------------------
$before = @{}
foreach ($f in $plan.Files) { $before[$f.Name] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
$result = Invoke-Clean -Plan $plan
Assert-That ($result.Moved -eq 2 -and -not $result.Stopped) "moved 2 files (got $($result.Moved), left: $($result.Left -join ', '))"
Assert-That (-not (Test-Path -LiteralPath "$work\$a")) 'file a is gone from the folder'
Assert-That (-not (Test-Path -LiteralPath "$work\$b")) 'file b is gone from the folder'
$bd = $result.BatchDir
Assert-That ($bd -and $bd.StartsWith($hold + '\')) 'files went into a batch folder inside the holding folder'
Assert-That ((Test-Path -LiteralPath "$bd\$a") -and (Test-Path -LiteralPath "$bd\$b")) 'both files are in the batch folder'
Assert-That ((Get-FileHash -LiteralPath "$bd\$a" -Algorithm SHA256).Hash -eq $before[$a] -and (Get-FileHash -LiteralPath "$bd\$b" -Algorithm SHA256).Hash -eq $before[$b]) 'held files are byte-for-byte identical'
$mf = Get-Content -LiteralPath "$bd\manifest.json" -Raw | ConvertFrom-Json
Assert-That ($mf.SourceFolder -eq $work -and @($mf.Files).Count -eq 2 -and @($mf.Files | Where-Object Status -eq 'moved').Count -eq 2) 'manifest records the original folder and both files as moved'
Assert-That ([System.IO.File]::Exists("$work\hidden.txt")) 'hidden file untouched'
Assert-That ([System.IO.File]::Exists("$work\system.dat")) 'system file untouched'
Assert-That (Test-Path -LiteralPath "$work\Keep-Me\inner.txt") 'file inside subfolder untouched'
Assert-That (Test-Path -LiteralPath "$ext\outside.txt") 'file behind a junction untouched'
Assert-That (Test-Path -LiteralPath "$ext\sub\deep.txt") 'nested file behind a junction untouched'
if ($symlinkMade) { Assert-That (Test-Path -LiteralPath "$ext\outside.txt") 'symlink target untouched' }
$bin = (New-Object -ComObject Shell.Application).NameSpace(10)
Assert-That (@($bin.Items() | Where-Object { $_.Name -like "*fc-$id*" }).Count -eq 0) 'nothing was sent to the Recycle Bin (the app does not use it)'

# --- put back ----------------------------------------------------------------
$held = @(Get-HeldBatches -HoldingRoot $hold)
Assert-That ($held.Count -eq 1 -and $held[0].Count -eq 2) 'the held batch is listed with 2 files'
Set-Content -LiteralPath "$work\$b" -Value 'a different file with the same name'
$rest = Restore-Batch -BatchDir $held[0].Dir -HoldingRoot $hold
Assert-That ($rest.Restored -eq 1 -and $rest.Left.Count -eq 1) "restore puts back 1 file and leaves 1 whose name is taken (restored $($rest.Restored), left $($rest.Left.Count))"
Assert-That ((Get-Content -LiteralPath "$work\$b" -Raw).Trim() -eq 'a different file with the same name') 'a file with the same name was NOT overwritten'
Assert-That (Test-Path -LiteralPath "$bd\$b") 'the file that could not go back is still safe in the holding folder'
Assert-That ((Get-FileHash -LiteralPath "$work\$a" -Algorithm SHA256).Hash -eq $before[$a]) 'restored file is byte-for-byte identical'
$rest2 = Restore-Batch -BatchDir $held[0].Dir -HoldingRoot (Join-Path $root 'elsewhere')
Assert-That ($rest2.Error -ne '') 'restore refuses a batch that is not inside the holding folder'

# --- failures leave files in place ---------------------------------------------
$f1 = "$root\fail"
New-Item -ItemType Directory -Path $f1 | Out-Null
foreach ($n in 'one','two','three') { Set-Content -LiteralPath "$f1\fc-$id-$n.txt" -Value $n }
$fp = Get-CleanPlan -Path $f1 -HoldingRoot "$root\hold2"
$lock = [System.IO.File]::Open("$f1\fc-$id-two.txt", 'Open', 'Read', 'None')
$fr = Invoke-Clean -Plan $fp
$lock.Close()
Assert-That ($fr.Moved -eq 2 -and $fr.Left.Count -eq 1) "a file that is open elsewhere stays in place, the others move (moved $($fr.Moved), left $($fr.Left.Count))"
Assert-That (Test-Path -LiteralPath "$f1\fc-$id-two.txt") 'the locked file is still in its folder'
$mf2 = Get-Content -LiteralPath "$($fr.BatchDir)\manifest.json" -Raw | ConvertFrom-Json
Assert-That (@($mf2.Files | Where-Object Status -eq 'left').Count -eq 1) 'manifest records the file that stayed'

# name already used in the batch folder: never overwritten
$f2 = "$root\collide"
New-Item -ItemType Directory -Path $f2 | Out-Null
Set-Content -LiteralPath "$f2\fc-$id-x.txt" -Value 'new'
$cp = Get-CleanPlan -Path $f2 -HoldingRoot "$root\hold3"
New-Item -ItemType Directory -Path "$root\hold3\fixedbatch" -Force | Out-Null
Set-Content -LiteralPath "$root\hold3\fixedbatch\fc-$id-x.txt" -Value 'existing'
$cr = Invoke-Clean -Plan $cp -BatchName 'fixedbatch'
Assert-That ($cr.Stopped -or $cr.Moved -eq 0) 'an existing batch folder is not reused'
$cr2 = Invoke-Clean -Plan $cp -BatchName 'fixedbatch2'
Assert-That ($cr2.Moved -eq 1) 'a fresh batch folder works'

# holding folder cannot be created
$blocker = "$root\notafolder.txt"
Set-Content -LiteralPath $blocker -Value 'x'
$f3 = "$root\nocreate"
New-Item -ItemType Directory -Path $f3 | Out-Null
Set-Content -LiteralPath "$f3\fc-$id-y.txt" -Value 'y'
$np = Get-CleanPlan -Path $f3 -HoldingRoot "$blocker\hold"
$nr = Invoke-Clean -Plan $np
Assert-That ($nr.Moved -eq 0 -and $nr.Stopped -and (Test-Path -LiteralPath "$f3\fc-$id-y.txt")) 'if the holding folder cannot be created, nothing moves'

# holding folder reached through a junction is refused
New-Item -ItemType Directory -Path "$root\hold4real" | Out-Null
cmd /c mklink /J "$root\hold4" "$root\hold4real" | Out-Null
$f4 = "$root\viajunction"
New-Item -ItemType Directory -Path $f4 | Out-Null
Set-Content -LiteralPath "$f4\fc-$id-z.txt" -Value 'z'
$jp = Get-CleanPlan -Path $f4 -HoldingRoot "$root\hold4\sub"
Assert-That (-not $jp.Ok) 'a holding folder behind a junction is refused'
Assert-That (Test-Path -LiteralPath "$f4\fc-$id-z.txt") 'file still in place after the refusal'

# --- ten files: all of them come back, byte for byte --------------------------
$bulk = "$root\bulk"
New-Item -ItemType Directory -Path $bulk | Out-Null
$hashes = @{}
foreach ($n in 1..10) { $p = "$bulk\fc-$id-bulk$n.dat"; [System.IO.File]::WriteAllBytes($p, (New-Object byte[] (1000 * $n))); $hashes["fc-$id-bulk$n.dat"] = $n }
$bp = Get-CleanPlan -Path $bulk -HoldingRoot "$root\hold5"
$br = Invoke-Clean -Plan $bp
Assert-That ($br.Moved -eq 10 -and @(Get-ChildItem -LiteralPath $bulk -File).Count -eq 0) 'ten files moved, folder is empty'
$bh = @(Get-HeldBatches -HoldingRoot "$root\hold5")
Assert-That ($bh.Count -eq 1 -and $bh[0].Count -eq 10) 'the held batch counts 10 files (the count is files, not batches)'
$brs = Restore-Batch -BatchDir $bh[0].Dir -HoldingRoot "$root\hold5"
$sizesOk = $true
foreach ($k in $hashes.Keys) { if ((Get-Item -LiteralPath "$bulk\$k").Length -ne (1000 * $hashes[$k])) { $sizesOk = $false } }
Assert-That ($brs.Restored -eq 10 -and $brs.Left.Count -eq 0 -and @(Get-ChildItem -LiteralPath $bulk -File).Count -eq 10 -and $sizesOk) 'all 10 files are put back with the right sizes'
Assert-That (@(Get-HeldBatches -HoldingRoot "$root\hold5").Count -eq 0) 'nothing is left held after the put-back'

# --- moves never cross drives and never copy -------------------------------------
$otherDrive = $null
foreach ($d in [System.IO.DriveInfo]::GetDrives()) { if ($d.DriveType -eq 'Fixed' -and $d.IsReady -and $d.Name -ne 'C:\') { $otherDrive = $d.Name; break } }
if ($otherDrive) {
    $xd = "${otherDrive}FC-Test-$id-xdrive"
    New-Item -ItemType Directory -Path $xd | Out-Null
    Set-Content -LiteralPath "$root\fc-$id-cross.txt" -Value 'cross'
    $rc = [FcNative]::MoveSameVolume("$root\fc-$id-cross.txt", "$xd\fc-$id-cross.txt")
    Assert-That ($rc -ne 0) "a move to another drive fails instead of copying (error code $rc)"
    Assert-That ((Test-Path -LiteralPath "$root\fc-$id-cross.txt") -and -not (Test-Path -LiteralPath "$xd\fc-$id-cross.txt")) 'the file stays put and nothing was copied'
    Remove-Item -LiteralPath $xd -Recurse -Force
} else { Write-Host 'NOTE  no second drive on this machine; the cross-drive check is skipped' }

# --- a refused plan does nothing --------------------------------------------
$bad = Get-CleanPlan -Path $env:SystemRoot
$res3 = Invoke-Clean -Plan $bad
Assert-That ($res3.Moved -eq 0) 'a refused plan moves nothing'

# --- the app has no delete code ----------------------------------------------
$src = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\FolderClear.ps1') -Raw
Assert-That ($src -notmatch '(?i)Remove-Item|\.Delete\(|DeleteFile|InvokeVerb|SHFileOperation|IFileOperation|NameSpace\(10\)|rd /s|rmdir') 'the app source contains no delete or Recycle Bin call'

# --- cleanup of this test's own throwaway folders (junctions first) ------------
cmd /c rmdir "$work\LinkedFolder" | Out-Null
cmd /c rmdir "$root\JunctionToExternal" | Out-Null
cmd /c rmdir "$root\hold4" | Out-Null
Remove-Item -LiteralPath $root -Recurse -Force
Remove-Item -LiteralPath $ext -Recurse -Force

if ($script:failures -gt 0) { Write-Host "$($script:failures) check(s) failed"; exit 1 }
Write-Host 'All checks passed'
