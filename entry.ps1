. $PSScriptRoot\batch_convert.ps1
. $PSScriptRoot\sign_deploy_run.ps1

# Please enter the credentials to log into the MSIX Packaging Tool VM.
[string]$userName = 'msixtool'
[string]$userPassword = 'msixtool'

# Convert to SecureString
[securestring]$secStringPassword = ConvertTo-SecureString $userPassword -AsPlainText -Force
[pscredential]$credential = New-Object System.Management.Automation.PSCredential ($userName, $secStringPassword)

# We need to do some work inside the Virtual Machine, this scriptblock will handle that.
$Scriptblock = {
    param (
        [Parameter()]
        $RemoteComputerName
    )
    
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    New-NetFirewallRule -Name "Allow WinRM HTTPS" -DisplayName "WinRM HTTPS" -Enabled True -Profile Any -Action Allow -Direction Inbound -LocalPort 5986 -Protocol TCP | Out-Null
    New-NetFirewallRule -Name "Allow MSIX Packaging" -DisplayName "MSIX Packaging" -Enabled True -Profile Any -Action Allow -Direction Inbound -LocalPort 1599 -Protocol TCP | Out-Null
    New-NetFirewallRule -DisplayName "ICMPv4" -Direction Inbound -Action Allow -Protocol icmpv4 -Enabled True | Out-Null

    $thumbprint = (New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My -FriendlyName $env:COMPUTERNAME -KeyExportPolicy NonExportable).Thumbprint
    $command = "winrm create winrm/config/Listener?Address=*+Transport=HTTPS @{Hostname=""$env:COMPUTERNAME"";CertificateThumbprint=""$thumbprint""}"
    cmd.exe /C $command 
    Export-Certificate -Cert Cert:\LocalMachine\My\$thumbprint -FilePath "C:\WinRMCert.crt"
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $RemoteComputerName -Force
        
}

# Enter the name of the Virtual Machine(s) that is/are used to create the Package.
$virtualMachines = @(
    @{ Name = "MSIX Packaging Tool Environment"; Credential = $credential }
)

# Make sure that Remote Powershell is enabled, en that the default MSIX remote port is open. And create the Certificate that is needed.
if ($virtualMachines) {
    foreach ($vm in $virtualMachines) {
        if (!(Test-Path "HKLM:\Software\CloudAssist\MSIXTool\$vm")) {
            Invoke-Command -VMName $vm.Name -ScriptBlock $Scriptblock -Credential $credential -ArgumentList ($env:COMPUTERNAME)
            $session = New-PSSession -VMName $vm.Name -Credential $credential
            Copy-Item -Path "C:\WinRMCert.crt" -Destination "C:\Packages\WinRMCert.crt" -FromSession $session
            Import-Certificate -FilePath "C:\Packages\WinRMCert.crt" -CertStoreLocation Cert:\LocalMachine\My
            Remove-PSSession -Session $session
            New-Item -Path "HKLM:\Software\CloudAssist\MSIXTool\$vm" -force | Out-Null
        }
    }
}

# It is also possible to use an Azure VM. In this example not used.
$remoteMachines = @(
    #@{ ComputerName = "YourVMNameHere.westus.cloudapp.azure.com"; Credential = $credential }
)

# USE A MINIMUM OF 4 DIGITS FOR THE VERSION!
# WHEN USING AN .EXE USE THE ARGUMENTS, NOT NECESSARY IF MSI!
$conversionsParameters = @(
    @{
        InstallerPath        = "C:\Packages\Installers\npp.7.9.5.Installer.x64.exe";
        InstallerArguments   = "/S";
        PackageName          = "NotepadPlusPlus";
        PackageDisplayName   = "Notepad++";
        PublisherName        = "CN=CloudAssist";
        PublisherDisplayName = "CloudAssist";
        PackageVersion       = "7.9.5.0"
    }
)

# Create OUT directory based on ScriptRoot
$workingDirectory = [System.IO.Path]::Combine($PSScriptRoot, "out")

write-host "Starting conversion jobs... Please wait..."
RunConversionJobs -conversionsParameters $conversionsParameters -virtualMachines $virtualMachines -remoteMachines $remoteMachines $workingDirectory

write-host "Start signing package:"
SignAndDeploy "$workingDirectory\MSIX"