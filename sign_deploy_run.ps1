function SignAndDeploy($msixFolder)
{

    Get-ChildItem $msixFolder | foreach-object {
        $pfxFilePath = "C:\pathtopfx.pfx"
        $msixPath = $_.FullName
        Write-Host "Running: signtool.exe sign /f $global:common_pfxLocation /fd SHA256 $path"
        & "./redistr/signtool.exe" sign /f $pfxFilePath /fd SHA256 $msixPath
        Add-AppxPackage $msixPath
    }
}