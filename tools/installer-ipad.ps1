# Prépare l'installation de ProRange Creator sur l'iPad, en un double-clic :
# 1. télécharge le .ipa de la dernière build verte (GitHub Actions) ;
# 2. installe iloader depuis sa page officielle s'il n'est pas déjà là ;
# 3. ferme Sideloadly et AltServer (ils occupent la connexion avec l'iPad) ;
# 4. copie le chemin du .ipa dans le presse-papiers et ouvre iloader.
# Restent manuels (imposés par Apple et par iloader, sans mode ligne de commande) : la connexion à l'identifiant
# Apple (une seule fois si on coche l'enregistrement), « Import IPA » + Ctrl+V, et la confiance sur l'iPad.

$ErrorActionPreference = 'Stop'
$repo = 'polopaulyvpe/ProRangeCreator'
$gh = 'C:\Program Files\GitHub CLI\gh.exe'
$dest = Join-Path $env:USERPROFILE 'Downloads\ProRangeCreator-ipa'
$ipa = Join-Path $dest 'ProRangeCreator.ipa'

function Step($text) { Write-Host ''; Write-Host $text -ForegroundColor Cyan }

function Find-ILoader {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'iloader\iloader.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\iloader\iloader.exe'),
        (Join-Path $env:LOCALAPPDATA 'iloader\iloader.exe')
    )
    foreach ($path in $candidates) { if (Test-Path $path) { return $path } }
    $found = Get-ChildItem -Path $env:ProgramFiles, (Join-Path $env:LOCALAPPDATA 'Programs') -Filter 'iloader.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

try {
    Step '1/4  Telechargement du dernier ProRange Creator (build verte)...'
    if (-not (Test-Path $gh)) { throw "GitHub CLI introuvable ($gh). Installe-le avec : winget install GitHub.cli" }
    $runId = & $gh run list --repo $repo --status success --limit 1 --json databaseId -q '.[0].databaseId'
    if (-not $runId) { throw 'Aucune build verte trouvee sur GitHub.' }
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    & $gh run download $runId --repo $repo --name ProRangeCreator-ipa --dir $dest
    if (-not (Test-Path $ipa)) { throw 'Le .ipa n''a pas ete telecharge.' }
    Write-Host "     OK : $ipa"

    Step '2/4  Verification d''iloader...'
    $iloader = Find-ILoader
    if (-not $iloader) {
        Write-Host '     iloader absent : telechargement depuis github.com/nab138/iloader (version officielle)...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $msi = Join-Path $env:TEMP 'iloader-windows-x64.msi'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/nab138/iloader/releases/latest/download/iloader-windows-x64.msi' -OutFile $msi
        $signature = Get-AuthenticodeSignature $msi
        Write-Host "     Signature Windows du fichier : $($signature.Status)"
        Write-Host '     Installation (Windows peut demander une autorisation)...'
        $process = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/passive' -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Installation d'iloader echouee (code $($process.ExitCode))." }
        $iloader = Find-ILoader
        if (-not $iloader) { throw 'iloader installe mais introuvable : ouvre-le depuis le menu Demarrer.' }
    }
    Write-Host "     OK : $iloader"

    Step '3/4  Fermeture de Sideloadly et AltServer...'
    Get-Process -Name 'sideloadly*', 'AltServer*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '     OK'

    Step '4/4  Ouverture d''iloader...'
    Set-Clipboard -Value $ipa
    Start-Process -FilePath $iloader
    Write-Host '     OK : le chemin du .ipa est dans le presse-papiers.'

    Write-Host ''
    Write-Host 'A faire dans iloader :' -ForegroundColor Green
    Write-Host '  - iPad branche et deverrouille.'
    Write-Host '  - Premiere fois seulement : connecte-toi a ton identifiant Apple en cochant l''enregistrement.'
    Write-Host '  - Clique sur Import IPA, puis Ctrl+V dans la fenetre de fichier et Entree.'
    Write-Host '  - Premiere fois seulement, sur l''iPad : Reglages > General > VPN et gestion de l''appareil > Faire confiance.'
    Write-Host '  - A refaire tous les 7 jours : double-clic sur le raccourci, Import IPA, Ctrl+V.'
}
catch {
    Write-Host ''
    Write-Host "Erreur : $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ''
Read-Host 'Appuie sur Entree pour fermer cette fenetre'
