[CmdletBinding()]
param(
    [string]$Collection,
    [string]$OutputDirectory = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Zotero结构化导出'),
    [string]$AnnotatedPdfDirectory,
    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ApiBase = 'http://127.0.0.1:23119/api/users/0'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Invoke-ZoteroJson {
    param([Parameter(Mandatory)][string]$Path)

    $url = if ($Path.StartsWith('http')) { $Path } else { "$ApiBase$Path" }
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        & curl.exe --silent --show-error --fail --compressed --output $tempFile $url
        if ($LASTEXITCODE -ne 0) {
            throw "无法访问 Zotero 本地接口：$url。请确认 Zotero 已启动，并已启用本地 API。"
        }
        $text = [System.IO.File]::ReadAllText($tempFile, [System.Text.UTF8Encoding]::new($false))
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Get-ZoteroPaged {
    param([Parameter(Mandatory)][string]$Path)

    $all = [System.Collections.Generic.List[object]]::new()
    $start = 0
    do {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $decoded = Invoke-ZoteroJson "$Path${separator}limit=100&start=$start"
        $pageCount = 0
        foreach ($entry in $decoded) {
            $all.Add($entry)
            $pageCount++
        }
        $start += $pageCount
    } while ($pageCount -eq 100)
    foreach ($entry in $all) { Write-Output $entry }
}

function ConvertTo-SafeName {
    param(
        [AllowEmptyString()][string]$Name,
        [int]$MaxLength = 100
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = '未命名' }
    $safe = $Name -replace '[<>:"/\\|?*\x00-\x1F]', ' '
    $safe = $safe -replace '\s+', ' '
    $safe = $safe.Trim().TrimEnd('.')
    if ($safe -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $safe = "_$safe" }
    if ($safe.Length -gt $MaxLength) { $safe = $safe.Substring(0, $MaxLength).Trim().TrimEnd('.') }
    if ([string]::IsNullOrWhiteSpace($safe)) { return '未命名' }
    return $safe
}

function Get-UniqueDirectory {
    param([string]$Parent, [string]$Name, [string]$Key)

    $candidate = Join-Path $Parent $Name
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    return Join-Path $Parent (ConvertTo-SafeName "$Name [$Key]" 112)
}

function Get-LocalFilePath {
    param([Parameter(Mandatory)][string]$ItemKey)

    $raw = & curl.exe --silent --show-error --fail "$ApiBase/items/$ItemKey/file/view/url"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($raw -join ''))) { return $null }
    $url = ($raw -join '').Trim()
    try {
        $uri = [Uri]$url
        return [Uri]::UnescapeDataString($uri.LocalPath)
    }
    catch { return $null }
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Encode-Html {
    param([AllowNull()][object]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-SafeNoteHtml {
    param([AllowEmptyString()][string]$Html)

    if ([string]::IsNullOrEmpty($Html)) { return '' }

    # Exported notes may be shared and opened outside Zotero. Remove active
    # content and event handlers before saving the HTML document.
    $safe = [regex]::Replace($Html, '(?is)<\s*(script|iframe|object|embed|form|button|input|textarea|select)\b[^>]*>.*?<\s*/\s*\1\s*>', '')
    $safe = [regex]::Replace($safe, '(?is)<\s*(script|iframe|object|embed|link|meta|form|button|input|textarea|select)\b[^>]*?/?>', '')
    $safe = [regex]::Replace($safe, '(?i)\s+on[a-z0-9_-]+\s*=\s*"[^"]*"', '')
    $safe = [regex]::Replace($safe, "(?i)\s+on[a-z0-9_-]+\s*=\s*'[^']*'", '')
    $safe = [regex]::Replace($safe, '(?i)\s+on[a-z0-9_-]+\s*=\s*[^\s>]+', '')
    $safe = [regex]::Replace($safe, '(?i)\s+(href|src)\s*=\s*"[\s\x00-\x20]*(javascript|vbscript|data):[^"]*"', '')
    $safe = [regex]::Replace($safe, "(?i)\s+(href|src)\s*=\s*'[\s\x00-\x20]*(javascript|vbscript|data):[^']*'", '')
    $safe = [regex]::Replace($safe, '(?i)\s+(href|src)\s*=\s*[\s\x00-\x20]*(javascript|vbscript|data):[^\s>]+', '')
    $safe = [regex]::Replace($safe, '(?i)\s+style\s*=\s*"[^"]*(url\s*\(|expression\s*\()[^"]*"', '')
    $safe = [regex]::Replace($safe, "(?i)\s+style\s*=\s*'[^']*(url\s*\(|expression\s*\()[^']*'", '')
    return $safe
}

function New-SafeExternalLink {
    param([AllowEmptyString()][string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $uri = $null
    if ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')) {
        $encoded = Encode-Html $uri.AbsoluteUri
        return "<a href=`"$encoded`" rel=`"noreferrer noopener`">$encoded</a>"
    }
    return Encode-Html $Url
}

function Get-ItemBaseName {
    param($Item)

    $data = $Item.data
    $author = '无作者'
    if ($data.creators -and $data.creators.Count -gt 0) {
        $first = $data.creators | Where-Object { $_.creatorType -eq 'author' } | Select-Object -First 1
        if (-not $first) { $first = $data.creators | Select-Object -First 1 }
        if ($first.lastName) { $author = $first.lastName }
        elseif ($first.name) { $author = $first.name }
    }
    $year = '无年份'
    if ($Item.meta.parsedDate -match '(19|20)\d{2}') { $year = $Matches[0] }
    elseif ($data.date -match '(19|20)\d{2}') { $year = $Matches[0] }
    $title = if ($data.title) { $data.title } elseif ($data.itemType -eq 'note') { '独立笔记' } else { $data.itemType }
    return ConvertTo-SafeName "$author-$year-$title" 72
}

function New-HtmlDocument {
    param([string]$Title, [string]$Body)

    $encodedTitle = Encode-Html $Title
    return @"
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$encodedTitle</title>
<style>
html{overflow-x:auto}body{font-family:"Segoe UI","Microsoft YaHei",sans-serif;line-height:1.75;max-width:1200px;margin:40px auto;padding:0 24px;color:#202124;background:#fff;overflow:visible}
h1{font-size:1.7rem;line-height:1.35;border-bottom:1px solid #ddd;padding-bottom:.6rem}h2{margin-top:2rem}
img{max-width:100%!important;width:auto!important;height:auto!important;border:1px solid #e5e5e5;border-radius:4px}a{color:#1769aa;overflow-wrap:anywhere;word-break:break-word}
table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid #ddd;padding:.65rem;text-align:left;vertical-align:top}th{width:8rem;background:#f7f7f7}
.muted{color:#666;font-size:.92rem}.note{margin:1rem 0;max-width:100%;overflow:visible;overflow-wrap:anywhere;word-break:break-word}.note pre{white-space:pre-wrap;overflow-wrap:anywhere}.note table{display:block;max-width:100%;overflow-x:auto}.note blockquote{margin-left:0;padding-left:1rem;border-left:4px solid #ddd}.highlight{background:#fff3a3}.citation{color:#555}
.plain-backup{margin-top:2rem;border-top:1px solid #ddd;padding-top:1rem}.plain-backup summary{cursor:pointer;color:#1769aa}.plain-note{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;background:#f7f7f7;padding:1rem;border-radius:4px}
.warning{padding:.8rem 1rem;background:#fff3cd;border-left:4px solid #e0a800;border-radius:4px;color:#594400}
</style>
</head>
<body>
$Body
</body>
</html>
"@
}

function Export-NoteHtml {
    param($NoteItem, [string]$NotesDirectory, [int]$Index)

    $imagesDirectory = Join-Path $NotesDirectory 'images'
    $noteHtml = [string]$NoteItem.data.note
    $imageKeys = [regex]::Matches($noteHtml, 'data-attachment-key="([A-Z0-9]+)"') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique

    foreach ($imageKey in $imageKeys) {
        $source = Get-LocalFilePath $imageKey
        if (-not $source -or -not (Test-Path -LiteralPath $source)) { continue }
        New-Item -ItemType Directory -Force -Path $imagesDirectory | Out-Null
        $extension = [System.IO.Path]::GetExtension($source)
        if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.png' }
        $imageName = "$imageKey$extension"
        Copy-Item -LiteralPath $source -Destination (Join-Path $imagesDirectory $imageName) -Force
        $relative = "images/$imageName"
        $pattern = "(<img\b[^>]*data-attachment-key=`"$imageKey`"[^>]*)(>)"
        $noteHtml = [regex]::Replace($noteHtml, $pattern, {
            param($match)
            $tag = $match.Groups[1].Value
            if ($tag -match '\ssrc=') { $tag = $tag -replace '\ssrc="[^"]*"', " src=`"$relative`"" }
            else { $tag += " src=`"$relative`"" }
            return $tag + $match.Groups[2].Value
        })
    }

    # Zotero uses large data-* attributes for live citations and annotations.
    # Ordinary browsers do not need them, and malformed/stale values can affect rendering.
    $noteHtml = [regex]::Replace($noteHtml, '\sdata-[a-zA-Z0-9_-]+="[^"]*"', '')
    $noteHtml = ConvertTo-SafeNoteHtml $noteHtml

    # Always include an independently encoded plain-text copy so every saved character
    # remains readable even if a browser handles a complex note tag differently.
    $plainText = [string]$NoteItem.data.note
    $plainText = [regex]::Replace($plainText, '(?i)<br\s*/?>', "`n")
    $plainText = [regex]::Replace($plainText, '(?i)</(p|div|li|blockquote|h[1-6])>', "`n")
    $plainText = [regex]::Replace($plainText, '<[^>]+>', '')
    $plainText = [System.Net.WebUtility]::HtmlDecode($plainText)
    $plainText = [regex]::Replace($plainText, "[ \t]+(`r?`n)", '$1')
    $plainText = [regex]::Replace($plainText, "(`r?`n){3,}", "`n`n").Trim()

    $label = if ($NoteItem.data.title) { $NoteItem.data.title } else { "阅读笔记-$('{0:D2}' -f $Index)" }
    $fileName = if ($Index -eq 1) { '阅读笔记.html' } else { "阅读笔记-$('{0:D2}' -f $Index).html" }
    $status = "已导出 Zotero 当前保存的笔记字段：$($NoteItem.data.note.Length) 个 HTML 字符，$($imageKeys.Count) 张内嵌图片。"
    $backup = "<details class=`"plain-backup`"><summary>查看纯文本完整备份</summary><pre class=`"plain-note`">$(Encode-Html $plainText)</pre></details>"
    $body = "<h1>$(Encode-Html $label)</h1><p class=`"muted`">$(Encode-Html $status)</p><div class=`"note`">$noteHtml</div>$backup"
    Write-Utf8File (Join-Path $NotesDirectory $fileName) (New-HtmlDocument $label $body)
}

function Export-MetadataHtml {
    param($Item, [string]$ItemDirectory)

    $data = $Item.data
    $authors = @($data.creators | ForEach-Object {
        if ($_.name) { $_.name } else { ("$($_.firstName) $($_.lastName)").Trim() }
    }) -join '；'
    $tags = @($data.tags | ForEach-Object { $_.tag }) -join '；'
    $urlCell = New-SafeExternalLink ([string]$data.url)
    $doiCell = if ($data.DOI) { "<a href=`"https://doi.org/$(Encode-Html $data.DOI)`">$(Encode-Html $data.DOI)</a>" } else { '' }
    $rows = @(
        @('标题', $data.title), @('作者', $authors), @('年份/日期', $data.date),
        @('文献类型', $data.itemType), @('期刊/出版物', $data.publicationTitle),
        @('卷', $data.volume), @('期', $data.issue), @('页码', $data.pages),
        @('DOI', $doiCell), @('网址', $urlCell), @('标签', $tags), @('Zotero 条目键', $data.key)
    )
    $tableRows = foreach ($row in $rows) {
        $value = if ($row[0] -in @('DOI','网址')) { $row[1] } else { Encode-Html $row[1] }
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { "<tr><th>$(Encode-Html $row[0])</th><td>$value</td></tr>" }
    }
    $title = if ($data.title) { $data.title } else { '文献信息' }
    $body = "<h1>$(Encode-Html $title)</h1><table>$($tableRows -join "`n")</table>"
    Write-Utf8File (Join-Path $ItemDirectory '文献信息.html') (New-HtmlDocument $title $body)
}

function Copy-Attachment {
    param($Attachment, [string]$ItemDirectory, [string]$ReadableBaseName, [int]$PdfIndex)

    $data = $Attachment.data
    if ($data.linkMode -eq 'linked_url') { return $PdfIndex }
    $source = Get-LocalFilePath $data.key
    if (-not $source -or -not (Test-Path -LiteralPath $source)) { return $PdfIndex }

    if ($data.contentType -eq 'application/pdf' -or [System.IO.Path]::GetExtension($source) -ieq '.pdf') {
        $targetDir = Join-Path $ItemDirectory 'PDF原文'
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        $suffix = if ($PdfIndex -eq 0) { '' } else { "-$($PdfIndex + 1)" }
        $available = [Math]::Max(24, [Math]::Min(100, 235 - $targetDir.Length - $suffix.Length - 5))
        $copySource = $source
        $annotationLabel = ''
        $sourceName = [System.IO.Path]::GetFileName($source)
        if ($script:AnnotatedPdfLookup -and $script:AnnotatedPdfLookup.ContainsKey($sourceName)) {
            $copySource = $script:AnnotatedPdfLookup[$sourceName]
            $annotationLabel = '-含批注'
        }
        $targetName = "$(ConvertTo-SafeName $ReadableBaseName $available)$suffix$annotationLabel.pdf"
        Copy-Item -LiteralPath $copySource -Destination (Join-Path $targetDir $targetName) -Force
        return ($PdfIndex + 1)
    }

    if ($data.contentType -eq 'text/html' -or [System.IO.Path]::GetExtension($source) -ieq '.html') {
        $targetDir = Join-Path $ItemDirectory '网页快照'
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        $snapshotTitle = if ($data.title) { $data.title } else { '网页快照' }
        $snapshotDir = Join-Path $targetDir (ConvertTo-SafeName $snapshotTitle 80)
        Copy-Item -LiteralPath (Split-Path -Parent $source) -Destination $snapshotDir -Recurse -Force
        return $PdfIndex
    }

    if ($data.linkMode -ne 'embedded_image') {
        $targetDir = Join-Path $ItemDirectory '附件'
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        Copy-Item -LiteralPath $source -Destination (Join-Path $targetDir (ConvertTo-SafeName ([System.IO.Path]::GetFileName($source)) 128)) -Force
    }
    return $PdfIndex
}

function Export-ZoteroItem {
    param($Item, [string]$CollectionDirectory)

    $baseName = Get-ItemBaseName $Item
    $itemDir = Get-UniqueDirectory $CollectionDirectory $baseName $Item.key
    New-Item -ItemType Directory -Force -Path $itemDir | Out-Null
    Export-MetadataHtml $Item $itemDir

    $children = @(Get-ZoteroPaged "/items/$($Item.key)/children?")
    $notes = @($children | Where-Object { $_.data.itemType -eq 'note' })
    $attachments = @($children | Where-Object { $_.data.itemType -eq 'attachment' -and $_.data.linkMode -ne 'embedded_image' })

    if ($Item.data.itemType -eq 'note') { $notes = @($Item) }
    if ($Item.data.itemType -eq 'attachment') { $attachments = @($Item) }

    if ($notes.Count -gt 0) {
        $notesDir = Join-Path $itemDir '笔记'
        New-Item -ItemType Directory -Force -Path $notesDir | Out-Null
        for ($i = 0; $i -lt $notes.Count; $i++) { Export-NoteHtml $notes[$i] $notesDir ($i + 1) }
    }

    $pdfIndex = 0
    foreach ($attachment in $attachments) {
        $pdfIndex = Copy-Attachment $attachment $itemDir $baseName $pdfIndex
    }
    return $itemDir
}

function Export-CollectionRecursive {
    param($CollectionItem, [string]$ParentDirectory, [object[]]$AllCollections)

    $collectionName = ConvertTo-SafeName $CollectionItem.data.name 90
    $collectionDir = Join-Path $ParentDirectory $collectionName
    New-Item -ItemType Directory -Force -Path $collectionDir | Out-Null
    Write-Host "导出收藏夹：$($CollectionItem.data.name)"

    $items = @(Get-ZoteroPaged "/collections/$($CollectionItem.key)/items/top?")
    $count = 0
    foreach ($item in $items) {
        Export-ZoteroItem $item $collectionDir | Out-Null
        $count++
        Write-Host "  [$count/$($items.Count)] $($item.data.title)"
    }

    $children = @($AllCollections | Where-Object { $_.data.parentCollection -eq $CollectionItem.key } | Sort-Object { $_.data.name })
    foreach ($child in $children) { Export-CollectionRecursive $child $collectionDir $AllCollections }
}

function Test-ZoteroApi {
    $status = & curl.exe --silent --output NUL --write-out '%{http_code}' 'http://127.0.0.1:23119/api/schema'
    return ($LASTEXITCODE -eq 0 -and (($status -join '').Trim() -eq '200'))
}

function Find-ZoteroExecutable {
    $running = Get-Process zotero -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.Path -and (Test-Path -LiteralPath $running.Path)) { return $running.Path }

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\zotero.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\zotero.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\zotero.exe'
    )
    foreach ($registryPath in $registryPaths) {
        if (Test-Path -LiteralPath $registryPath) {
            $candidate = (Get-Item -LiteralPath $registryPath).GetValue('')
            if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
        }
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Zotero\zotero.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Zotero\zotero.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Zotero\zotero.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

if (-not (Test-ZoteroApi)) {
    $zoteroProcess = Get-Process zotero -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $zoteroProcess) {
        $zoteroExecutable = Find-ZoteroExecutable
        if ($zoteroExecutable) {
            Write-Host 'Zotero 尚未运行，正在自动启动并等待本地接口……' -ForegroundColor Yellow
            Start-Process -FilePath $zoteroExecutable | Out-Null
        }
        else {
            Write-Host '无法找到 Zotero 程序。请手动启动 Zotero 后重新运行。' -ForegroundColor Red
            exit 2
        }
    }
    else {
        Write-Host 'Zotero 正在启动，正在等待本地接口……' -ForegroundColor Yellow
    }

    $apiReady = $false
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        Start-Sleep -Seconds 1
        if (Test-ZoteroApi) {
            $apiReady = $true
            break
        }
    }
    if (-not $apiReady) {
        Write-Host '仍无法连接 Zotero 本地接口。请在 Zotero 的“设置 → 高级 → API”中确认已启用本地 API，然后重试。' -ForegroundColor Red
        exit 2
    }
}

$collections = @(Get-ZoteroPaged '/collections?')
$interactiveMode = [string]::IsNullOrWhiteSpace($Collection)
if ($interactiveMode) {
    Write-Host "`n可用收藏夹："
    foreach ($entry in ($collections | Sort-Object { $_.data.name })) {
        Write-Host "  $($entry.key)  $($entry.data.name)"
    }
    $Collection = Read-Host "`n请输入收藏夹名称或上方 8 位键"
}

$matches = @($collections | Where-Object { $_.key -eq $Collection -or $_.data.name -eq $Collection })
if ($matches.Count -eq 0) { throw "没有找到收藏夹：$Collection" }
if ($matches.Count -gt 1) { throw "存在多个同名收藏夹，请改用上方显示的 8 位收藏夹键。" }
$selected = $matches[0]

if ($interactiveMode -and [string]::IsNullOrWhiteSpace($AnnotatedPdfDirectory)) {
    Write-Host "`n如需让 PDF 保留 Zotero 高亮和批注："
    Write-Host '请先在 Zotero 中选择文献，使用“文件 → 导出 PDF”，勾选包含批注，并导出到一个临时文件夹。'
    $AnnotatedPdfDirectory = Read-Host '输入该临时文件夹路径；不需要批注可直接按 Enter'
}

$script:AnnotatedPdfLookup = @{}
if (-not [string]::IsNullOrWhiteSpace($AnnotatedPdfDirectory)) {
    $annotatedRoot = [System.IO.Path]::GetFullPath($AnnotatedPdfDirectory.Trim('"'))
    if (-not (Test-Path -LiteralPath $annotatedRoot -PathType Container)) {
        throw "带批注 PDF 文件夹不存在：$annotatedRoot"
    }
    foreach ($pdf in (Get-ChildItem -LiteralPath $annotatedRoot -Recurse -File -Filter '*.pdf')) {
        if (-not $script:AnnotatedPdfLookup.ContainsKey($pdf.Name)) {
            $script:AnnotatedPdfLookup[$pdf.Name] = $pdf.FullName
        }
    }
    Write-Host "已载入 $($script:AnnotatedPdfLookup.Count) 个候选带批注 PDF。"
}

$root = [System.IO.Path]::GetFullPath($OutputDirectory)
if ((Test-Path -LiteralPath $root) -and -not $Overwrite) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $root = "$root-$stamp"
}
New-Item -ItemType Directory -Force -Path $root | Out-Null

Export-CollectionRecursive $selected $root $collections

Write-Host "`n导出完成：$root" -ForegroundColor Green
Write-Output $root

