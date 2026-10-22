param([switch]$SelfTest, [switch]$LibraryOnly)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
Add-Type -TypeDefinition @'
public static class CodexSwitcherAtomicFile {
    public static void Replace(string source, string destination) {
        System.IO.File.Replace(source, destination, null);
    }
}
'@

function Get-IdentityKey([string]$Raw) {
    $auth = $Raw | ConvertFrom-Json
    if ($auth.auth_mode -ne 'chatgpt' -or -not $auth.tokens.account_id -or
        -not $auth.tokens.id_token -or -not $auth.tokens.access_token -or
        -not $auth.tokens.refresh_token) {
        throw '仅支持通过 Codex 官方登录得到的 ChatGPT 账号；此登录记录不符合要求。'
    }
    # This decode labels a locally obtained login; it does not authenticate a JWT.
    $parts = $auth.tokens.id_token.Split('.')
    if ($parts.Length -ne 3) { throw '登录记录格式异常，请重新通过 Codex 登录。' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    $payload += '=' * ((4 - $payload.Length % 4) % 4)
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    if (-not $claims.sub) { throw '登录记录缺少账号身份，请重新登录。' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$claims.sub + '|' + [string]$auth.tokens.account_id)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Protect-Text([string]$Raw) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Raw)
    return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
}

function Unprotect-Text([string]$Encrypted) {
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        [Convert]::FromBase64String($Encrypted), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Write-Atomic([string]$Path, [string]$Value) {
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, $Value, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [CodexSwitcherAtomicFile]::Replace($temp, $Path) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Assert-Closed {
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('ChatGPT', 'Codex', 'codex', 'codex-code-mode-host')
    })
    if ($running.Count -gt 0) {
        throw '请先结束当前任务，并完全退出 Codex / ChatGPT 桌面应用及 Codex 命令行，再切换账号。这个工具不会强制关闭它们。'
    }
}

function Assert-Configuration {
    $config = Join-Path $script:CodexHome 'config.toml'
    if (Test-Path -LiteralPath $config) {
        $raw = [IO.File]::ReadAllText($config)
        if ($raw -match '(?m)^\s*cli_auth_credentials_store\s*=\s*["''](?:keyring|auto|ephemeral)["'']') {
            throw '此配置未明确使用文件登录凭据，不能安全应用本工具。请使用 Codex 内置登录切换。'
        }
        if ($raw -match '(?m)^\s*forced_chatgpt_workspace_id\s*=') {
            throw '此配置限制了登录工作空间，不能使用此切换器。'
        }
        if ($raw -match '(?m)^\s*forced_login_method\s*=\s*["'']api["'']') {
            throw '此配置限定 API 登录，不能使用此切换器。'
        }
    }
}

function Get-Profiles {
    return @(Get-ChildItem -LiteralPath $script:Store -Filter '*.profile.json' -File | ForEach-Object {
        $p = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json
        if ($p.home -eq $script:CodexHome) { $p }
    } | Sort-Object label)
}

function Save-Profile([string]$Raw, [string]$Label) {
    $key = Get-IdentityKey $Raw
    $path = Join-Path $script:Store ($key + '.profile.json')
    if ([IO.File]::Exists($path) -and [string]::IsNullOrWhiteSpace($Label)) {
        $Label = ([IO.File]::ReadAllText($path) | ConvertFrom-Json).label
    }
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = '未命名账号 ' + $key.Substring(0, 6) }
    if ($Label.Trim().Length -gt 60) { throw '账号名称请控制在 60 个字以内。' }
    $record = [ordered]@{version=1; key=$key; label=$Label.Trim(); home=$script:CodexHome;
        savedAt=(Get-Date).ToString('o'); encryptedAuth=(Protect-Text $Raw)}
    Write-Atomic $path ($record | ConvertTo-Json -Depth 4)
    return $key
}

function Switch-Profile($Profile) {
    Assert-Closed
    Assert-Configuration
    if ($Profile.home -ne $script:CodexHome) { throw '账号记录属于另一个 Codex 数据目录。' }
    $target = Unprotect-Text $Profile.encryptedAuth
    if ((Get-IdentityKey $target) -ne $Profile.key) { throw '账号记录校验失败，未切换。' }
    if (-not [IO.File]::Exists($script:AuthPath)) { throw '当前登录文件不存在。请先通过 Codex 正常登录并保存账号。' }
    $current = [IO.File]::ReadAllText($script:AuthPath)
    $currentKey = Get-IdentityKey $current
    if ($currentKey -eq $Profile.key) {
        Save-Profile $current $Profile.label | Out-Null
        return '当前已是这个账号，已更新它的登录快照。'
    }
    # Capture rotated refresh tokens before restoring another account.
    Save-Profile $current '' | Out-Null
    $recovery = [ordered]@{home=$script:CodexHome; encryptedAuth=(Protect-Text $current)}
    Write-Atomic (Join-Path $script:Store 'recovery.json') ($recovery | ConvertTo-Json)
    Assert-Closed
    Write-Atomic $script:AuthPath $target
    try {
        if ((Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))) -ne $Profile.key) {
            throw '切换后的记录校验失败。'
        }
    } catch {
        Write-Atomic $script:AuthPath $current
        throw '切换校验失败，已恢复原登录记录。'
    }
    return ('已切换登录记录到「' + $Profile.label + '」。现在从原来的快捷方式打开 Codex，进入原聊天继续。是否能跨账号续聊仍需实际验证。')
}

if ($LibraryOnly) { return }

if ($SelfTest) {
    $script:CodexHome = Join-Path $env:TEMP ('codex-switcher-test-' + [Guid]::NewGuid().ToString('N'))
    $script:Store = Join-Path $script:CodexHome 'profiles'
    [IO.Directory]::CreateDirectory($script:Store) | Out-Null
    $script:AuthPath = Join-Path $script:CodexHome 'auth.json'
    function Make-FakeAuth([string]$Id) {
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"sub":"' + $Id + '"}')).TrimEnd('=').Replace('+','-').Replace('/','_')
        return (@{auth_mode='chatgpt'; tokens=@{account_id=$Id; id_token=('x.'+$payload+'.x'); access_token='FAKE'; refresh_token='FAKE'}} | ConvertTo-Json)
    }
    try {
        $a = Make-FakeAuth 'FAKE-A'; $b = Make-FakeAuth 'FAKE-B'
        if ((Unprotect-Text (Protect-Text $a)) -ne $a) { throw 'Encryption test failed' }
        Write-Atomic $script:AuthPath $a
        $keyA = Save-Profile $a 'A'; $keyB = Save-Profile $b 'B'
        if ((Get-Profiles).Count -ne 2) { throw 'Profile test failed' }
        Write-Atomic $script:AuthPath $b
        if ((Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))) -ne $keyB) { throw 'Atomic test failed' }
        $invalidRejected = $false
        try { Get-IdentityKey '{"auth_mode":"apikey"}' | Out-Null } catch { $invalidRejected = $true }
        if (-not $invalidRejected) { throw 'Validation test failed' }
        $processGuardWorks = $false
        try { Assert-Closed } catch { $processGuardWorks = $true }
        if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.ProcessName -in @('ChatGPT','codex','Codex','codex-code-mode-host')}).Count -gt 0 -and -not $processGuardWorks) { throw 'Process guard test failed' }
        # Allow the production switch path only inside this isolated fake-data test.
        function Assert-Closed {}
        $sentinel = Join-Path $script:CodexHome 'history-do-not-touch.jsonl'
        [IO.File]::WriteAllText($sentinel, 'FAKE CHAT HISTORY')
        Write-Atomic $script:AuthPath $a
        $selectedB = Get-Profiles | Where-Object { $_.key -eq $keyB }
        Switch-Profile $selectedB | Out-Null
        if ((Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))) -ne $keyB) { throw 'Switch test failed' }
        $recovery = [IO.File]::ReadAllText((Join-Path $script:Store 'recovery.json')) | ConvertFrom-Json
        if ((Get-IdentityKey (Unprotect-Text $recovery.encryptedAuth)) -ne $keyA) { throw 'Recovery test failed' }
        $selectedA = Get-Profiles | Where-Object { $_.key -eq $keyA }
        Switch-Profile $selectedA | Out-Null
        if ((Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))) -ne $keyA) { throw 'Return switch test failed' }
        if ([IO.File]::ReadAllText($sentinel) -ne 'FAKE CHAT HISTORY') { throw 'History preservation test failed' }
        Write-Output 'PASS: Windows encryption, separate profiles, A-B-A switching, recovery, history preservation, invalid-record rejection, running-app guard. Only fake credentials used.'
    } finally {
        # Delete only the explicitly created, verified test directory.
        $resolved = [IO.Path]::GetFullPath($script:CodexHome)
        $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolved).StartsWith('codex-switcher-test-')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:CodexHome = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
$script:AuthPath = Join-Path $script:CodexHome 'auth.json'
# Protected records stay on this Windows user account; no credentials ship with this tool.
$script:Store = Join-Path $env:LOCALAPPDATA 'CodexAccountSwitcher/profiles'
[IO.Directory]::CreateDirectory($script:Store) | Out-Null
$mutex = New-Object Threading.Mutex($false, 'Local\CodexAccountSwitcher')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit }

$form = New-Object Windows.Forms.Form
$form.Text = 'Codex 多账号切换器'
$form.Size = New-Object Drawing.Size(670, 560)
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
$intro = New-Object Windows.Forms.Label
$intro.SetBounds(20, 16, 610, 65)
$intro.Text = "保存账号 → 完全退出 Codex → 切换账号 → 重开原聊天。`r`n工具只更换本地登录记录；跨账号续聊需要实测。"
$homeLabel = New-Object Windows.Forms.Label
$homeLabel.SetBounds(20, 82, 610, 45)
$homeLabel.Text = '共用数据目录：' + $script:CodexHome
$list = New-Object Windows.Forms.ListBox
$list.SetBounds(20, 133, 610, 145)
$list.DisplayMember = 'label'
$nameBox = New-Object Windows.Forms.TextBox
$nameBox.SetBounds(20, 290, 290, 30)
$nameBox.Text = '账号 A'
$saveButton = New-Object Windows.Forms.Button
$saveButton.SetBounds(325, 288, 305, 34)
$saveButton.Text = '保存 / 更新当前已登录账号'
$switchButton = New-Object Windows.Forms.Button
$switchButton.SetBounds(20, 335, 290, 40)
$switchButton.Text = '切换到选中的账号'
$restoreButton = New-Object Windows.Forms.Button
$restoreButton.SetBounds(325, 335, 305, 40)
$restoreButton.Text = '恢复上一次切换前的登录'
$status = New-Object Windows.Forms.Label
$status.SetBounds(20, 390, 610, 120)
$status.Text = "首次添加另一个账号：通过 Codex 官方入口登录 B，回来把名称改为账号 B，再点保存。`r`n凭据使用 Windows 用户加密；可随时重新登录更新。"
function Refresh-List {
    $list.Items.Clear()
    foreach ($p in (Get-Profiles)) { $list.Items.Add($p) | Out-Null }
}
function Show-Failure {
    $status.Text = [string]$_.Exception.Message
    [Windows.Forms.MessageBox]::Show($status.Text, '尚未完成', 'OK', 'Information') | Out-Null
}
$saveButton.Add_Click({
    try {
        Assert-Configuration
        if (-not [IO.File]::Exists($script:AuthPath)) { throw '未找到登录记录。请先打开 Codex 并正常登录。' }
        if ([string]::IsNullOrWhiteSpace($nameBox.Text)) { throw '请填写一个账号名称，例如账号 A。' }
        Save-Profile ([IO.File]::ReadAllText($script:AuthPath)) $nameBox.Text | Out-Null
        Refresh-List
        $status.Text = '已加密保存当前账号。可通过 Codex 官方入口登录另一个账号后，再保存一次。'
    } catch { Show-Failure }
})
$switchButton.Add_Click({
    try {
        if (-not $list.SelectedItem) { throw '请先选中一个已保存的账号。' }
        $status.Text = Switch-Profile $list.SelectedItem
        Refresh-List
    } catch { Show-Failure }
})
$restoreButton.Add_Click({
    try {
        Assert-Closed
        Assert-Configuration
        $recoveryPath = Join-Path $script:Store 'recovery.json'
        if (-not [IO.File]::Exists($recoveryPath)) { throw '尚无可恢复的切换记录。' }
        $p = [IO.File]::ReadAllText($recoveryPath) | ConvertFrom-Json
        if ($p.home -ne $script:CodexHome) { throw '恢复记录属于另一个 Codex 数据目录。' }
        $raw = Unprotect-Text $p.encryptedAuth
        Get-IdentityKey $raw | Out-Null
        if ([IO.File]::Exists($script:AuthPath)) { Save-Profile ([IO.File]::ReadAllText($script:AuthPath)) '' | Out-Null }
        Assert-Closed
        Write-Atomic $script:AuthPath $raw
        $status.Text = '已恢复切换前的登录记录。请通过原快捷方式重新打开 Codex。'
        Refresh-List
    } catch { Show-Failure }
})
$form.Controls.AddRange(@($intro,$homeLabel,$list,$nameBox,$saveButton,$switchButton,$restoreButton,$status))
try { Refresh-List; [void]$form.ShowDialog() } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
