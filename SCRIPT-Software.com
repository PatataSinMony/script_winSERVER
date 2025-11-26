# ================================================================
# CONFIGURACIÓN DE OUs Y GRUPOS DEL DOMINIO
# ================================================================

# OU donde irán los usuarios creados automáticamente
$OUUsuarios = "OU=Usuarios-OU,DC=software,DC=com"

# Contraseña inicial para los usuarios
$contrasenaInicialPlano = 'S00-usc0:.,'
$contrasenaSegura = ConvertTo-SecureString $contrasenaInicialPlano -AsPlainText -Force

# Nombre DNS del dominio
$dominioDNS = (Get-ADDomain).DNSRoot

# Nombres de los grupos de cada área
$groupRectoria = "Rectoria-GRP"
$groupTH = "TH-GRP"
$groupSoftware = "Software-GRP"

# ================================================================
# FUNCIÓN PARA OBTENER EL ÚLTIMO NÚMERO USADO EN LA SECUENCIA
# ================================================================

function Obtener-UltimoNumeroUsuario {

    # Se listan usuarios cuyo SamAccountName inicia con "Usuario"
    $usuarios = Get-ADUser -Filter 'SamAccountName -like "Usuario*"' `
                -SearchBase $OUUsuarios |
                Select-Object -ExpandProperty SamAccountName -ErrorAction SilentlyContinue

    if (-not $usuarios -or $usuarios.Count -eq 0) { return 0 }

    # Extrae el número final (ejemplo: Usuario51 -> 51)
    $numeros = foreach ($u in $usuarios) {
        if ($u -match "^Usuario(\d+)$") { [int]$matches[1] }
    }

    if ($numeros) {
        ($numeros | Measure-Object -Maximum).Maximum
    }
    else {
        return 0
    }
}

# ================================================================
# CREACIÓN INICIAL DE 50 USUARIOS (Usuario01 – Usuario50)
# ================================================================

$numUsuariosIniciales = 50
$primerUsuarioNombre = "Usuario01"

# Verificación si ya existe Usuario01
$usuarioInicialExiste = Get-ADUser -Filter "SamAccountName -eq '$primerUsuarioNombre'" `
                          -ErrorAction SilentlyContinue

if ($usuarioInicialExiste) {

    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "LOS USUARIOS INICIALES YA EXISTEN (Usuario01–Usuario50)." -ForegroundColor Red
    Write-Host "Se omite su creación y se continúa con la parte interactiva." -ForegroundColor Red
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
}
else {

    Write-Host "Creando los primeros $numUsuariosIniciales usuarios..." -ForegroundColor Green

    for ($i = 1; $i -le $numUsuariosIniciales; $i++) {

        $nuevoNumFormato = "{0:d2}" -f $i
        $username = "Usuario$nuevoNumFormato"
        $displayName = "Usuario $nuevoNumFormato"

        Write-Host "Creando $username ..."

        New-ADUser `
            -Name $displayName `
            -SamAccountName $username `
            -UserPrincipalName "$username@$dominioDNS" `
            -AccountPassword $contrasenaSegura `
            -Enabled $true `
            -Path $OUUsuarios `
            -ChangePasswordAtLogon $true -ErrorAction Stop

        # Asignación automática según rango
        if ($i -ge 1 -and $i -le 10) {
            Add-ADGroupMember -Identity $groupRectoria -Members $username
            Write-Host "  -> Asignado a $groupRectoria"
        }
        elseif ($i -ge 11 -and $i -le 30) {
            Add-ADGroupMember -Identity $groupTH -Members $username
            Write-Host "  -> Asignado a $groupTH"
        }
        else {
            Add-ADGroupMember -Identity $groupSoftware -Members $username
            Write-Host "  -> Asignado a $groupSoftware"
        }
    }

    Write-Host "Usuarios iniciales creados exitosamente." -ForegroundColor Green
}

# ================================================================
# MODO INTERACTIVO PARA CREAR NUEVOS LOTES DE USUARIOS
# ================================================================

while ($true) {

    Write-Host ""
    $respuesta = Read-Host "¿Desea crear más usuarios? (si/no)"

    if ($respuesta -notin @("si","SI","Si","s","S")) {
        Write-Host "Proceso completado." -ForegroundColor Green
        break
    }

    $cantidad = Read-Host "¿Cuántos usuarios desea crear?"

    if (-not ($cantidad -as [int]) -or ([int]$cantidad -le 0)) {
        Write-Host "Valor inválido. Ingrese un número mayor a cero." -ForegroundColor Red
        continue
    }

    $cantidad = [int]$cantidad

    Write-Host ""
    Write-Host "Elija el grupo al que se asignarán los usuarios:"
    Write-Host "1 = Rectoria-GRP"
    Write-Host "2 = TH-GRP"
    Write-Host "3 = Software-GRP"
    Write-Host ""

    $opcionGrupo = Read-Host "Seleccione (1/2/3)"

    switch ($opcionGrupo) {
        "1" { $grupoSeleccionado = $groupRectoria }
        "2" { $grupoSeleccionado = $groupTH }
        "3" { $grupoSeleccionado = $groupSoftware }
        default {
            Write-Host "Opción inválida." -ForegroundColor Red
            continue
        }
    }

    $ultimo = Obtener-UltimoNumeroUsuario
    $usuariosCreados = 0

    Write-Host "Creando $cantidad usuarios a partir del número $($ultimo + 1)..." -ForegroundColor Cyan

    for ($x = 1; $x -le $cantidad; $x++) {

        $ultimo = $ultimo + 1
        $nuevoNumFormato = "$ultimo"
        $username = "Usuario$nuevoNumFormato"
        $displayName = "Usuario $nuevoNumFormato"

        try {

            New-ADUser `
                -Name $displayName `
                -SamAccountName $username `
                -UserPrincipalName "$username@$dominioDNS" `
                -AccountPassword $contrasenaSegura `
                -Enabled $true `
                -Path $OUUsuarios `
                -ChangePasswordAtLogon $true -ErrorAction Stop

            Add-ADGroupMember -Identity $grupoSeleccionado -Members $username

            Write-Host " -> $username creado y asignado a $grupoSeleccionado" -ForegroundColor DarkGray
            $usuariosCreados++
        }
        catch {
            Write-Host "ERROR creando $username: $($_.Exception.Message)" -ForegroundColor Red
            $ultimo = $ultimo - 1
            break
        }
    }

    Write-Host "Usuarios creados en este lote: $usuariosCreados" -ForegroundColor Cyan
}
