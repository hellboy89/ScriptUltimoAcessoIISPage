Clear-Host
Get-Date
Write-Host "===============================" -ForegroundColor Yellow
Import-Module WebAdministration

# ==========================================================
$site          = "teste.iuven.com.br"
$ultimasLinhas = 20
$paisFiltro    = "Brazil"
# ==========================================================

# Localizar o diretório de logs do site
$logDir  = (Get-ItemProperty "IIS:\Sites\$site" -Name logfile).directory
$logDir  = [Environment]::ExpandEnvironmentVariables($logDir)
$siteId  = (Get-Website -Name $site).id
$logFolder = Join-Path $logDir "W3SVC$siteId"

Write-Host "`nCARREGANDO... AGUARDE!" -ForegroundColor Yellow

# --- Traduz o codigo HTTP para uma descricao legivel ----------------------
function Get-StatusDescricao {
    param([string]$codigo)
    $texto = switch ($codigo) {
        "200" { "Sucesso (OK)" }
        "201" { "Sucesso (Criado)" }
        "204" { "Sucesso (Sem conteudo)" }
        "301" { "Redirecionado (permanente)" }
        "302" { "Redirecionado (temporario)" }
        "304" { "Sem alteracao (cache)" }
        "400" { "Falha (Requisicao invalida)" }
        "401" { "Falha (Nao autenticado)" }
        "403" { "Falha (Acesso negado)" }
        "404" { "Falha (Nao encontrado)" }
        "405" { "Falha (Metodo nao permitido)" }
        "408" { "Falha (Tempo esgotado)" }
        "429" { "Falha (Excesso de requisicoes)" }
        "500" { "Falha (Erro interno)" }
        "502" { "Falha (Gateway invalido)" }
        "503" { "Falha (Servico indisponivel)" }
        default {
            if     ($codigo -match "^2") { "Sucesso" }
            elseif ($codigo -match "^3") { "Redirecionado" }
            elseif ($codigo -match "^4") { "Falha (cliente)" }
            elseif ($codigo -match "^5") { "Falha (servidor)" }
            else                          { "Desconhecido" }
        }
    }
    return $texto
}

# --- Geo lookup em LOTE + cache (evita 1 requisicao HTTP por IP) -----------
$geoCache = @{}
function Resolve-Paises {
    param([string[]]$ips)
    $novos = @($ips | Where-Object { $_ -and -not $geoCache.ContainsKey($_) } | Select-Object -Unique)
    for ($i = 0; $i -lt $novos.Count; $i += 100) {
        $fim  = [Math]::Min($i + 99, $novos.Count - 1)
        $lote = @($novos[$i..$fim])
        # forca array JSON mesmo com 1 elemento (compatibilidade PS 5.1)
        $body = '[' + (($lote | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
        try {
            $resp = Invoke-RestMethod -Uri "http://ip-api.com/batch?fields=country,query" `
                                      -Method Post -Body $body -TimeoutSec 10
            foreach ($r in $resp) { $geoCache[$r.query] = $r.country }
        } catch {
            foreach ($ip in $lote) { $geoCache[$ip] = "Desconhecido" }
        }
    }
}

# --- Ler somente o necessario, do log mais novo para o mais antigo ---------
$arquivos = Get-ChildItem "$logFolder\*.log" | Sort-Object LastWriteTime -Descending
$resultado = [System.Collections.Generic.List[object]]::new()
$vistos    = @{}   # IPs ja processados (dedupe global, preserva recencia)

foreach ($arq in $arquivos) {
    $linhas  = Get-Content $arq.FullName
    $headers = $null

    # mapear posicao das colunas a partir do cabecalho #Fields
    foreach ($l in $linhas) {
        if ($l -like "#Fields:*") {
            $headers = ($l -replace "#Fields: ", "").Split(" ")
            break
        }
    }
    if (-not $headers) { continue }
    $iDate   = [Array]::IndexOf($headers, "date")
    $iTime   = [Array]::IndexOf($headers, "time")
    $iIp     = [Array]::IndexOf($headers, "c-ip")
    $iMethod = [Array]::IndexOf($headers, "cs-method")
    $iUri    = [Array]::IndexOf($headers, "cs-uri-stem")
    $iStatus = [Array]::IndexOf($headers, "sc-status")

    # percorrer de tras para frente: linhas mais recentes primeiro
    $candidatos = [System.Collections.Generic.List[object]]::new()
    for ($k = $linhas.Count - 1; $k -ge 0; $k--) {
        $linha = $linhas[$k]
        if ($linha.StartsWith("#") -or [string]::IsNullOrWhiteSpace($linha)) { continue }
        $c  = $linha.Split(" ")
        $ip = $c[$iIp]
        if ($vistos.ContainsKey($ip)) { continue }
        $vistos[$ip] = $true
        $candidatos.Add([pscustomobject]@{
            date    = $c[$iDate]
            time    = $c[$iTime]
            IP      = $ip
            Metodo  = $c[$iMethod]
            URL     = $c[$iUri]
            Status  = $c[$iStatus]
        })
    }

    # geo em lote para os IPs novos deste arquivo
    Resolve-Paises -ips ($candidatos | ForEach-Object { $_.IP })

    foreach ($cand in $candidatos) {
        $pais = $geoCache[$cand.IP]
        if ($pais -eq $paisFiltro) {
            $cand | Add-Member -NotePropertyName 'Pais' -NotePropertyValue $pais -PassThru |
                Out-Null
            $resultado.Add($cand)
            if ($resultado.Count -ge $ultimasLinhas) { break }
        }
    }
    if ($resultado.Count -ge $ultimasLinhas) { break }
}

$resultado |
    Select-Object date, time, IP, Pais, Metodo, URL, Status,
                  @{N='Resultado'; E={ Get-StatusDescricao $_.Status }} |
    Format-Table -AutoSize
