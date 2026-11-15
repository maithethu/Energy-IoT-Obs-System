# Chụp ảnh 3 trang Streamlit bằng Microsoft Edge headless (phương án dự phòng demo – sped.md §9 R6).
#   powershell -File scripts/capture_screens.ps1 -Label ev031_02_vang
#   powershell -File scripts/capture_screens.ps1 -Label ev033_01_cam_bien -Station TRAM_Y -OutDir demo_backup
# Ảnh: <OutDir>/<Label>_1_dieu_hanh.png, _2_chi_tiet_<trạm>.png, _3_bao_cao.png
param(
    [Parameter(Mandatory = $true)][string]$Label,
    [string]$Station = "TRAM_Y",
    [string]$OutDir = "demo_backup",
    [string]$BaseUrl = "http://localhost:8501",
    [int]$WaitMs = 45000
)
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Error "Không tìm thấy Microsoft Edge"; exit 1 }
New-Item -ItemType Directory -Force $OutDir | Out-Null
# Profile mới mỗi lần chạy: profile dùng lại làm trang Điều hành (trang đầu) chụp ra trắng
$profileDir = Join-Path $env:TEMP ("edge_capture_" + [guid]::NewGuid().ToString("N"))
$pages = @(
    @{ Name = "1_dieu_hanh"; Url = "$BaseUrl/" },
    @{ Name = "2_chi_tiet_$Station"; Url = "$BaseUrl/chi-tiet-tram?tram=$Station" },
    @{ Name = "3_bao_cao"; Url = "$BaseUrl/bao-cao" }
)
function Invoke-Shot([string]$url, [string]$file) {
    if (Test-Path $file) { Remove-Item $file }
    # msedge.exe trả về ngay, tiến trình con mới ghi ảnh → chờ file xuất hiện (tối đa 75 giây)
    Start-Process -FilePath $edge -WindowStyle Hidden -ArgumentList @(
        "--headless=new", "--disable-gpu", "--hide-scrollbars", "--user-data-dir=`"$profileDir`"",
        "--window-size=1600,2200", "--virtual-time-budget=$WaitMs", "--screenshot=`"$file`"", $url)
    $deadline = (Get-Date).AddSeconds(75)
    while (-not (Test-Path $file) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    Start-Sleep -Milliseconds 500
}
# Làm nóng: lần mở đầu tiên Streamlit chưa kịp dựng trang (ảnh trắng) → chụp bỏ một lần
Invoke-Shot "$BaseUrl/" (Join-Path $env:TEMP "streamlit_warmup.png")
foreach ($p in $pages) {
    $file = Join-Path (Resolve-Path $OutDir) "$($Label)_$($p.Name).png"
    Invoke-Shot $p.Url $file
    if (Test-Path $file) { Write-Output "Đã chụp: $file" } else { Write-Warning "Không chụp được: $($p.Url)" }
}
