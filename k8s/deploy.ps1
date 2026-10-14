# PowerShell wrapper for deploy.sh: runs it with Git for Windows' bash.
# Plain "bash" in PowerShell is usually WSL's bash, which does not see the Windows helm/kubectl.
#
#   .\k8s\deploy.ps1 up|down|gnb|gnb-lite|gnb-o1
$ErrorActionPreference = 'Stop'

$git = (Get-Command git).Source                                  # ...\Git\cmd\git.exe
$bash = Join-Path (Split-Path (Split-Path $git)) 'bin\bash.exe'  # ...\Git\bin\bash.exe
if (-not (Test-Path $bash)) { throw "Git Bash not found at $bash" }

& $bash (Join-Path $PSScriptRoot 'deploy.sh') @args
exit $LASTEXITCODE
