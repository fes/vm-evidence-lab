import base64
import json
from pathlib import Path
import subprocess


def main():
    driver = Path(__file__).resolve().parents[1] / "interaction/windows/driver.ps1"
    script = r"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Get-Location) 'driver.ps1'), [ref] $tokens, [ref] $errors)
if ($errors.Count) { throw 'Driver parse failure' }
$writer = $ast.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Write-InteractionResult'
}, $true)
. ([ScriptBlock]::Create($writer.Extent.Text))

[Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437)
if ([Console]::OutputEncoding.CodePage -ne 437) { throw 'Expected OEM code page 437' }
$label = 'Public ' + [char] 0x00b7 + ' ' + [char] 0x4e2d
Write-InteractionResult '' ([ordered]@{label = $label}) ''
"""
    command = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    # Changing the code page affects only the child's separate, hidden console.
    startup = subprocess.STARTUPINFO(
        dwFlags=subprocess.STARTF_USESHOWWINDOW, wShowWindow=subprocess.SW_HIDE,
    )
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", command],
        cwd=driver.parent, stdin=subprocess.DEVNULL, capture_output=True, timeout=20,
        creationflags=subprocess.CREATE_NEW_CONSOLE, startupinfo=startup,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == '{"label":"Public \u00b7 \u4e2d"}\r\n'.encode("utf-8"), result.stdout
    assert json.loads(result.stdout.decode("utf-8")) == {"label": "Public \u00b7 \u4e2d"}
    print("Windows interaction stdout is exact UTF-8 under OEM code page 437.")


if __name__ == "__main__":
    main()
