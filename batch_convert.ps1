function CreateMPTTemplate($conversionParam, $jobId, $virtualMachine, $remoteMachine, $workingDirectory) {
    # create template file for this conversion
    $templateFilePath = [System.IO.Path]::Combine($workingDirectory, "MPT_Templates", "MsixPackagingToolTemplate_Job$($jobId).xml")
    $conversionMachine = ""
    if ($virtualMachine) {
        $conversionMachine = "<VirtualMachine Name=""$($vm.Name)"" Username=""$($vm.Credential.UserName)"" />"
    }
    else {
        $conversionMachine = "<mptv2:RemoteMachine ComputerName=""$($remoteMachine.ComputerName)"" Username=""$($remoteMachine.Credential.UserName)"" />"
    }
    $saveFolder = [System.IO.Path]::Combine($workingDirectory, "MSIX")
    $xmlContent = @"
<MsixPackagingToolTemplate
    xmlns="http://schemas.microsoft.com/appx/msixpackagingtool/template/2018"
    xmlns:mptv2="http://schemas.microsoft.com/msix/msixpackagingtool/template/1904">
<Installer Path="$($conversionParam.InstallerPath)" Arguments="$($conversionParam.InstallerArguments)" />
$conversionMachine
<SaveLocation PackagePath="$saveFolder" />
<PackageInformation
    PackageName="$($conversionParam.PackageName)"
    PackageDisplayName="$($conversionParam.PackageDisplayName)"
    PublisherName="$($conversionParam.PublisherName)"
    PublisherDisplayName="$($conversionParam.PublisherDisplayName)"
    Version="$($conversionParam.PackageVersion)">
</PackageInformation>
</MsixPackagingToolTemplate>
"@
    Set-Content -Value $xmlContent -Path $templateFilePath
    $templateFilePath
}

function RunConversionJobs($conversionsParameters, $virtualMachines, $remoteMachines, $workingDirectory) {
    New-Item -Force -Type Directory ([System.IO.Path]::Combine($workingDirectory, "MPT_Templates"))
    New-Item -Force -Type Directory ([System.IO.Path]::Combine($workingDirectory, "MSIX"))
    $initialSnapshotName = "BeforeMsixConversions_$(Get-Date -format FileDateTime)" 
    $runJobScriptPath = [System.IO.Path]::Combine($PSScriptRoot, "run_job.ps1")

    # create list of the indices of $conversionsParameters that haven't started running yet
    $remainingConversions = @()
    $conversionsParameters | Foreach-Object { $i = 0 } { $remainingConversions += ($i++) }

    # first schedule jobs on the remote machines. These machines will be recycled and will not be re-used to run additional conversions
    $remoteMachines | Foreach-Object {
        # select a job to run 
        Write-Host "Determining next job to run..."
        $conversionParam = $conversionsParameters[$remainingConversions[0]]
        Write-Host "Dequeuing conversion job for installer $($conversionParam.InstallerPath) on remote machine $($_.ComputerName)"

        # Capture the job index and update list of remaining conversions to run
        $jobId = $remainingConversions[0]
        $remainingConversions = $remainingConversions | Where-Object { $_ -ne $remainingConversions[0] }

        $templateFilePath = CreateMPTTemplate $conversionParam $jobId $nul $_ $workingDirectory 
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($_.Credential.Password)
        $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        Write-host "Starting Proces.. Please"
        $process = Start-Process "powershell.exe" -ArgumentList($runJobScriptPath, "-jobId", $jobId, "-machinePassword", $password, "-templateFilePath", $templateFilePath, "-workingDirectory", $workingDirectory) -PassThru

    }
    
    # Next schedule jobs on virtual machines which can be checkpointed/re-used
    # keep a mapping of VMs and the current job they're running, initialized ot null
    $vmsCurrentJobMap = @{}
    $virtualMachines | Foreach-Object { $vmsCurrentJobMap.Add($_.Name, $nul) }

    # Use a semaphore to signal when a machine is available. Note we need a global semaphore as the jobs are each started in a different powershell process
    $semaphore = New-Object -TypeName System.Threading.Semaphore -ArgumentList @($virtualMachines.Count, $virtualMachines.Count, "Global\MPTBatchConversion")

    while ($semaphore.WaitOne(-1)) {
        if ($remainingConversions.Count -gt 0) {
            # select a job to run 
            Write-Host "Determining next job to run..."
            $conversionParam = $conversionsParameters[$remainingConversions[0]]
            # select a VM to run it on. Retry a few times due to race between semaphore signaling and process completion status
            $vm = $nul
            while (-not $vm) { $vm = $virtualMachines | Where-Object { -not($vmsCurrentJobMap[$_.Name]) -or -not($vmsCurrentJobMap[$_.Name].ExitCode -eq $Nul) } | Select-Object -First 1 }
            $vmName = $vm.Name
            Write-Host "Dequeuing conversion job for installer $($conversionParam.InstallerPath) on VM $($vmName)"

            # Capture the job index and update list of remaining conversions to run
            $jobId = $remainingConversions[0]
            $remainingConversions = $remainingConversions | Where-Object { $_ -ne $remainingConversions[0] }

            $templateFilePath = CreateMPTTemplate $conversionParam $jobId $vm $nul $workingDirectory 
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($vm.Credential.Password)
            $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

            Write-Host "TemplateFilePath: $($TemplateFilePath) "
            Write-Host "Starting Process:"
        
            $process = Start-Process "powershell.exe" -ArgumentList("-file `"$runJobScriptPath`"", "-jobId", $jobId, "-vmName `"$vmName`"", "-vmsCount", $virtualMachines.Count, "-machinePassword", $password, "-templateFilePath `"$templateFilePath`"", "-initialSnapshotName", $initialSnapshotName) -PassThru
            $vmsCurrentJobMap[$vm.Name] = $process
        }
        else {
            $semaphore.Release()
            break;
        }

        Start-Sleep(1)
    }

    Write-Host "Finished scheduling all jobs"
    $virtualMachines | foreach-object { if ($vmsCurrentJobMap[$_.Name]) { $vmsCurrentJobMap[$_.Name].WaitForExit() } }
    $semaphore.Dispose()
    Read-Host -Prompt 'Press any key to continue '
    Write-Host "Finished running all jobs"
}