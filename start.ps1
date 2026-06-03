$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$Python = Get-Command python -ErrorAction SilentlyContinue
if ($Python) {
  & $Python.Source "$Root\start.py" @args
  exit $LASTEXITCODE
}

$PyLauncher = Get-Command py -ErrorAction SilentlyContinue
if ($PyLauncher) {
  & $PyLauncher.Source -3 "$Root\start.py" @args
  exit $LASTEXITCODE
}

Write-Error "Python was not found. Please install Python 3 or add it to PATH."
exit 1
