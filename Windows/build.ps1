param(
    [string]$Python='python',
    [string]$DistDir=(Join-Path $PSScriptRoot 'dist'),
    [string]$WorkDir=(Join-Path $PSScriptRoot 'build')
)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$dist=[IO.Path]::GetFullPath($DistDir);$work=[IO.Path]::GetFullPath($WorkDir)
$package=[IO.Path]::GetFullPath((Join-Path $dist 'SvanarControl'))
if($dist.Length -lt 5 -or -not $package.StartsWith($dist.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid scoped build directory'}
$marker=Join-Path $dist '.svanar-build-directory'
if((Test-Path -LiteralPath $package) -and -not(Test-Path -LiteralPath $marker)){throw 'Existing output is not a managed SVANAR build; choose a fresh DistDir'}
New-Item -ItemType Directory -Force $dist,$work | Out-Null
[IO.File]::WriteAllText($marker,'SVANAR Control managed package output',[Text.UTF8Encoding]::new($false))
function Run([string[]]$Arguments){& $Python @Arguments;if($LASTEXITCODE -ne 0){throw ('Python command failed: '+($Arguments -join ' '))}}
Run @('-m','unittest','discover','-s',$root,'-p','test_*.py','-v')
Run @('-m','PyInstaller','--noconfirm','--onedir','--windowed','--name','SvanarControl',
      '--distpath',$dist,'--workpath',(Join-Path $work 'pyinstaller'),'--specpath',$work,
      '--collect-submodules','comtypes','--collect-submodules','bleak',
      '--version-file',(Join-Path $root 'version_info.txt'),(Join-Path $root 'svanar_control.py'))
$exe=Join-Path $package 'SvanarControl.exe'
if(-not(Test-Path -LiteralPath $exe)){throw 'Compiled EXE not found'}
$smoke=Join-Path $work 'smoke-data';New-Item -ItemType Directory -Force $smoke|Out-Null
$previous=$env:SVANAR_CONTROL_DATA_DIR
try{
    $env:SVANAR_CONTROL_DATA_DIR=$smoke
    $process=Start-Process -FilePath $exe -ArgumentList '--smoke-ui' -WindowStyle Hidden -PassThru
    if(-not $process.WaitForExit(30000)){$process.Kill();throw 'EXE hidden UI smoke test timed out'}
    if($process.ExitCode -ne 0){throw ('EXE hidden UI smoke failed: '+$process.ExitCode)}
}finally{$env:SVANAR_CONTROL_DATA_DIR=$previous}
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $package 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $root 'EQ-file-example.json') -Destination (Join-Path $package 'EQ-file-example.json') -Force
Write-Output ('Built and smoke-tested: '+$exe)
