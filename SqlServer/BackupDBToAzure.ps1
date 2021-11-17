param(
    [string]$SQLInstance = $(throw "SQLInstance Parameter is not defined."),
    [string]$DatabaseName = $(throw "DatabaseName Parameter is not defined."),
    [string]$BakFileName = $(throw "BakFileName Parameter is not defined."),
    [string]$AzureSecretKey = $(throw "AzureSecretKey parameter is not defined"),
    [string]$AzureBlobAccount = $(throw "AzureBlobAccount parameter is not defined"),
    [string]$AzureBlobContainer = $(throw "AzureBlobContainer parameter is not defined"),
    [switch]$allowOverite
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    Import-Module SqlServer -ErrorAction Stop
}
catch {
    Write-Error "Unable to import the 'SqlServer' module, this module needs to be installed by 'Install-Module -Name SqlServer'"    
    exit 99
}

function Invoke-SqlCmdInternal([string]$database = $null, [string]$query) {
    if ($null -eq $database -or "" -eq $database) {
        $database = "master"
    }

    Invoke-Sqlcmd -ServerInstance $SQLInstance -Database $database -Query $query -ErrorAction Stop
}

function Add-AzureBlobBackupSQLCred {
    param (
        [string]$SQLInstance = $(throw "SQLInstance Parameter is not defined."),
        [string]$AzureSecretKey = $(throw "AzureSecretKey Parameter is not defined."),
        [string]$AzureBlobContainer = $(throw "AzureBlobContainer parameter is not defined"),
        [string]$AzureBlobAccount = $(throw "AzureBlobAccount parameter is not defined")
    )
    Write-Host "Checking for SQL Credentials"

    $CredName = "https://$($AzureBlobName).blob.core.windows.net/$($AzureBlobFolder)"

    # Testing if backup/restore credential is ok
    $SQLCred = "SELECT COUNT(name) FROM sys.credentials WHERE name = '$CredName'" 
    $SQLCredResult = (Invoke-SqlcmdInternal -Query $SQLCred ).Column1
    #Handle if there should be more than one credential, it shouldn't be able to happen, but just in case
    if ($SQLCredResult -gt 1) {
        $SQLCredResult = 1
    }    
    
    [System.Boolean]$SQLCredExist = $SQLCredResult
    
    if ($SQLCredExist) {
        Write-Host "Checking if credential is setup correct"
        $SQLCredCheck = "SELECT credential_identity FROM sys.credentials WHERE name = '$CredName'"
        $SQLCredCheckResult = ((Invoke-SqlcmdInternal -Query $SQLCredCheck).credential_identity).ToLower()
        if ($SQLCredCheckResult -NE $($AzureBlobAccount).ToLower()) {
            $SQLCredRemove = "DROP CREDENTIAL [$($CredName)]"
            Invoke-SqlcmdInternal -Query $SQLCredRemove
            $SQLCredExist = $false
        }
        else {
            Write-Host "Credential is correct"
        }
    }
    
    #If crediential is not on local machine, create it below
    if (!$SQLCredExist) {
        $SQLCredAdd = "CREATE CREDENTIAL [$($CredName)] WITH IDENTITY='$AzureBlobAccount', SECRET = '$AzureSecretKey'"
        Invoke-SqlcmdInternal -Query $SQLCredAdd 
        Write-Host "Added SQL backup credential"
    }        
}

function Backup-SqlDatabaseInternal([string]$backupUrl) {
    if ($allowOverite -eq $true) {
        Backup-SqlDatabase -ServerInstance $SQLInstance -Database $DatabaseName -BackupFile $backupUrl -SqlCredential $CredName -Initialize -FormatMedia -SkipTapeHeader -CompressionOption On 
    }
    else {
        Backup-SqlDatabase -ServerInstance $SQLInstance -Database $DatabaseName -BackupFile $backupUrl -SqlCredential $CredName -CompressionOption On -ErrorAction
    }
}


Add-AzureBlobBackupSQLCred -SQLInstance $SQLInstance -AzureSecretKey $AzureSecretKey -AzureBlobContainer $AzureBlobContainer -AzureBlobAccount $AzureBlobAccount


try {
    $File = $DatabaseName + $BakFileName
    $BackupFile = $CredName + "/" + $File
    Write-Output "Backing up $DatabaseName to $BackupFile"
    
    Backup-SqlDatabaseInternal -backupUrl $BackupFile

    Write-Output "Done backing up database"
}
catch {
    write-host $_.Exception
    Write-Error "Backup from didn't complete or something went wrong"
}