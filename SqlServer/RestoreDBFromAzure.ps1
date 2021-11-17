param(
    [string]$SQLInstance = $(throw "SQLInstance Parameter is not defined."),
    [string]$DatabaseName = $(throw "DatabaseName Parameter is not defined."),
    [string]$AzureSecretKey = $(throw "AzureSecretKey parameter is not defined"),
    [string]$AzureBlobAccount = $(throw "AzureBlobAccount parameter is not defined"),
    [string]$AzureBlobContainer = $(throw "AzureBlobContainer parameter is not defined"),
    [string]$BakFileName = $(throw "BakFileName Parameter is not defined."),
    [switch]$allowOverite
)

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

function Restore-SQLDatabaseFromAzure {
    param (
        [string]$SQLInstance = $(throw "SQLInstance Parameter is not defined."),
        [string]$DatabaseName = $(throw "DatabaseName Parameter is not defined."),
        [string]$FileName = $(throw "DatabaseName Parameter is not defined."),
        [string]$AzureSecretKey = $(throw "AzureSecretKey Parameter is not defined."),
        [string]$AzureBlobAccount = $(throw "AzureBlobAccount parameter is not defined"),
        [string]$AzureBlobContainer = $(throw "AzureBlobContainer parameter is not defined")
    )

    $CredName = "https://$($AzureBlobAccount).blob.core.windows.net/$($AzureBlobContainer)"
    $File = $CredName + '/' + $FileName
    
    Write-Output "Restoring $File to '$SQLServer' as '$DatabaseName'"

    # Check for existing database that does not start with $ and has an id > 4 (skipping master, tempdb, model and msdb)
    # If no database was found it will be created.
    $DatabaseCheck = "IF EXISTS (SELECT * FROM sys.sysdatabases WHERE dbid > 4 AND [name] not like '$' AND name = N'$DatabaseName')
    BEGIN
        SELECT 1;
    END
    ELSE
    BEGIN
        CREATE DATABASE $DatabaseName; 
        SELECT 0;
    END;"

    $databaseExists = (Invoke-SqlCmdInternal -Query $DatabaseCheck).Column1

    if ($databaseExists -eq 1 -and !$allowOverite)
    {
        throw "Database '$DatabaseName' already exists, and allowoverwite was set to false"
    }

    # Get Default File Locations fot the sql server instance
    $defaultFileLocations = Invoke-SqlcmdInternal -query "select SERVERPROPERTY('InstanceDefaultDataPath') as 'D', SERVERPROPERTY('InstanceDefaultLogPath') as 'L'"
   
    # Get the list of files from the backup
    $fileListQuery = "RESTORE FILELISTONLY FROM  URL = N'$File' with credential='$credname';"
    $dbfiles = Invoke-Sqlcmd -ServerInstance $SQLInstance -Database "tempdb" -Query $fileListQuery

    # Run through all files and give them new absolute paths mathching the file name of the new database
    $relocateFiles = @();
    foreach ($dbfile in $dbfiles) {
        # Get the extension of the file
        $extension = Split-Path $dbfile.PhysicalName -Extension
        # Build a new physical file name by looking up the type "D" for data "L" for log
        $physicalFile = Join-Path $defaultFileLocations[$dbfile.Type] "$DatabaseName$extension"

        # Build a new relocate command
        $relocate = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile($dbfile.LogicalName, $physicalFile)

        # add it to the list of relocations.
        $relocateFiles += $relocate
    }

    # Restore the database and relocate if needed.
    Restore-SqlDatabase -ServerInstance $SQLInstance -Database $DatabaseName -BackupFile $File -SqlCredential $CredName -ReplaceDatabase -RelocateFile $relocateFiles -AutoRelocateFile  
}

Add-AzureBlobBackupSQLCred -SQLInstance $SQLInstance -AzureSecretKey $AzureSecretKey -AzureBlobContainer $AzureBlobContainer -AzureBlobAccount $AzureBlobAccount

Restore-SQLDatabaseFromAzure -SQLInstance $SQLInstance -DatabaseName $DatabaseName -FileName $BakFileName -AzureSecretKey $AzureSecretKey -AzureBlobAccount $AzureBlobAccount -AzureBlobContainer $AzureBlobContainer
