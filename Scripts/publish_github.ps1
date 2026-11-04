param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')]
    [string]$Repository
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location -LiteralPath $root
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw '请先安装 GitHub CLI：https://cli.github.com/ ，然后重新打开 PowerShell。'
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw '需要先安装 Git。' }
& gh auth status
if ($LASTEXITCODE -ne 0) {
    & gh auth login --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { throw 'GitHub 登录未完成。' }
}
& gh auth setup-git
if ($LASTEXITCODE -ne 0) { throw 'Git 凭据配置失败。' }
& gh repo view $Repository --json name --jq .name
if ($LASTEXITCODE -ne 0) { throw '目标仓库不存在或无访问权限。请先新建空的私有仓库。' }
# Refuse to overwrite a populated repository or reuse unrelated local history.
$remote = "https://github.com/$Repository.git"
$branches = & git ls-remote --heads $remote
if ($LASTEXITCODE -ne 0) { throw '读取仓库失败。' }
if ($branches) { throw '请使用空仓库，脚本不会覆盖已有分支。' }
if (Test-Path -LiteralPath (Join-Path $root '.git')) { throw '目录已有 Git 历史，请手动推送或重新解压工程。' }
& git init -b main
if ($LASTEXITCODE -ne 0) { throw 'Git 初始化失败。' }
& git config user.name 'Svanar Control Builder'
& git config user.email 'svanar-builder@users.noreply.github.com'
& git add -- App Scripts Tests SvanarControl.xcodeproj .github .gitignore README.md
if ($LASTEXITCODE -ne 0) { throw '文件暂存失败。' }
& git commit -m 'Add native iOS headphone control and cloud IPA build'
if ($LASTEXITCODE -ne 0) { throw '提交失败。' }
& git remote add origin $remote
& git push -u origin main
if ($LASTEXITCODE -ne 0) { throw '推送失败；未强制覆盖远程内容。' }
# GitHub can take a moment to register a new workflow.
Start-Sleep -Seconds 5
& gh workflow run build-ios.yml --repo $Repository --ref main -f bundle_id=io.local.svanarcontrol -f sign=false
if ($LASTEXITCODE -ne 0) { throw '代码已上传；请在仓库 Actions 页面手动点击 Run workflow。' }
& gh repo view $Repository --web --branch main
Write-Host "已触发云构建。查看：https://github.com/$Repository/actions"
Write-Host '编译成功后从该次运行的 Artifacts 下载待签名 IPA。脚本不会上传证书或自动签名。'
