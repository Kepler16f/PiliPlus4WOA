param(
    [string]$Arg = ''
)

try {
    # 显示用版本后缀：应用「关于」页显示的版本、安装包文件名与 AppVersion
    # 都用「版本号 + 此后缀」。
    #
    # 为什么单独拆出来：pubspec.yaml 的 version 字段必须是合法 semver
    # （只允许 [0-9A-Za-z-]，不含下划线），所以带下划线的编号写不进 pubspec。
    # 于是 pubspec 里仍写合法的 2.1.4+<build>，对外用「2.1.4 + 此后缀」。
    # 现在跟随上游版本号，后缀留空（显示就是 2.1.4）；要区分本 fork 时
    # 改成 '_woa1' 这类即可。
    $versionDisplaySuffix = ''

    $versionName = $null

    $versionCode = [int](git rev-list --count HEAD).Trim()

    $commitHash = (git rev-parse HEAD).Trim()

    $updatedContent = foreach ($line in (Get-Content -Path 'pubspec.yaml' -Encoding UTF8)) {
        if ($line -match '^\s*version:\s*([\d\.]+)') {
            $versionName = $matches[1]
            if ($Arg -eq 'android') {
                $versionName += '-' + $commitHash.Substring(0, 9)
            }
            "version: $versionName+$versionCode"
        }
        else {
            $line
        }
    }

    if ($null -eq $versionName) {
        throw 'version not found'
    }

    $versionDisplay = $versionName + $versionDisplaySuffix

    $updatedContent | Set-Content -Path 'pubspec.yaml' -Encoding UTF8

    $buildTime = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())

    $data = @{
        'pili.name' = $versionDisplay
        'pili.code' = $versionCode
        'pili.hash' = $commitHash
        'pili.time' = $buildTime
    }

    $data | ConvertTo-Json -Compress | Out-File 'pili_release.json' -Encoding UTF8

    Add-Content -Path $env:GITHUB_ENV -Value "version=$versionDisplay+$versionCode"
}
catch {
    Write-Error "Prebuild Error: $($_.Exception.Message)"
    exit 1
}