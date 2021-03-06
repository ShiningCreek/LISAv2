# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
param(
    [String] $TestParams,
    [object] $AllVMData,
    [object] $CurrentTestData
)

function Main {
    param (
        $TestParams,
        $AllVMData
    )
    # Create test result
    $CurrentTestResult = Create-TestResultObject
    $resultArr = @()

    try {
        $noClient = $true
        $noServer = $true

        # role-0 vm is considered as the server-vm
        # role-1 vm is considered as the client-vm
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "server" -or $vmData.RoleName -imatch "role-0") {
                $serverVMData = $VmData
                $noServer = $false
            } elseif ($vmData.RoleName -imatch "client" -or $vmData.RoleName -imatch "role-1") {
                $clientVMData = $VmData
                $noClient = $false
            }
        }
        if ($noClient -or $noServer) {
            Throw "Client or Server VM not defined. Be sure that the SetupType has 2 VMs defined"
        }
        Write-LogInfo "SERVER VM details :"
        Write-LogInfo "  RoleName : $($serverVMData.RoleName)"
        Write-LogInfo "  Public IP : $($serverVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($serverVMData.SSHPort)"
        Write-LogInfo "CLIENT VM details :"
        Write-LogInfo "  RoleName : $($clientVMData.RoleName)"
        Write-LogInfo "  Public IP : $($clientVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($clientVMData.SSHPort)"

        # PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.
        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
        #endregion

        Write-LogInfo "Getting Active NIC Name."
        if ($TestPlatform -eq "HyperV") {
            $clientNicName = Get-GuestInterfaceByVSwitch $TestParams.PERF_NIC $clientVMData.RoleName `
                $clientVMData.HypervHost $user $clientVMData.PublicIP $password $clientVMData.SSHPort
            $serverNicName = Get-GuestInterfaceByVSwitch $TestParams.PERF_NIC $serverVMData.RoleName `
                $serverVMData.HypervHost $user $serverVMData.PublicIP $password $serverVMData.SSHPort
        } else {
            $getNicCmd = ". ./utils.sh &> /dev/null && get_active_nic_name"
            $clientNicName = (Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort `
                -username $user -password $password -command $getNicCmd).Trim()
            $serverNicName = (Run-LinuxCmd -ip $serverVMData.PublicIP -port $serverVMData.SSHPort `
                -username $user -password $password -command $getNicCmd).Trim()
        }

        if ($serverNicName -eq $clientNicName) {
            $nicName = $clientNicName
        } else {
            Throw "Server and client SRIOV NICs are not same."
        }
        if ($currentTestData.SetupConfig.Networking -imatch "SRIOV") {
            $DataPath = "SRIOV"
        } else {
            $DataPath = "Synthetic"
        }
        Write-LogInfo "CLIENT $DataPath NIC: $clientNicName"
        Write-LogInfo "SERVER $DataPath NIC: $serverNicName"

        Write-LogInfo "Generating constants.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "#Generated by LISAv2 Automation" -Path $constantsFile
        Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "nicName=$nicName" -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
        }
        Write-LogInfo "constants.sh created successfully..."
        Write-LogInfo (Get-Content -Path $constantsFile)

        if ($currentTestData.testName -imatch "PERF-APACHE-BENCHMARK") {
            $testName="Apache"
            $testName_lower="apache"
            $myString = @"
./perf_apache.sh &> apacheConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        } elseif ($currentTestData.testName -imatch "PERF-MEMCACHED-BENCHMARK") {
            $testName="Memcached"
            $testName_lower="memcached"
            $myString = @"
./perf_memcached.sh &> memcachedConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        }
        #region EXECUTE TEST

        Set-Content "$LogDir\Start${testName}Test.sh" $myString
        Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files "$constantsFile,$LogDir\Start${testName}Test.sh" -username $user -password $password -upload
        Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files $currentTestData.files -username $user -password $password -upload

        Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $user -password $password -command "chmod +x *.sh" -runAsSudo | Out-Null
        $testJob = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $user -password $password -command "./Start${testName}Test.sh" -RunInBackground -runAsSudo
        #endregion

        #region MONITOR TEST
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $user -password $password -command "tail -2 ${testName_lower}ConsoleLogs.txt | head -1"
            Write-LogInfo "Current Test Status : $currentStatus"
            Wait-Time -seconds 20
        }
        $finalStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $user -password $password -command "cat ./state.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username $user -password $password -download -downloadTo $LogDir -files "${testName_lower}ConsoleLogs.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username $user -password $password -download -downloadTo $LogDir -files "*${testName_lower}.bench.log"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username $user -password $password -download -downloadTo $LogDir -files "report.log, report.csv"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username $user -password $password -download -downloadTo $LogDir -files "VM_properties.csv"

        $uploadResults = $true
        $ReportLog = Get-Content -Path "$LogDir\report.log"
        if ($currentTestData.testName -imatch "PERF-APACHE-BENCHMARK") {
            foreach ($line in $ReportLog) {
                if ($line -imatch "WebServerVersion") {
                    continue;
                }
                try {
                    $testConcurrency = ($line.Trim() -Replace " +"," ").Split(" ")[1]
                    $requestsPerSec = ($line.Trim() -Replace " +"," ").Split(" ")[6]
                    $meanConnectionTime_ms = ($line.Trim() -Replace " +"," ").Split(" ")[8]
                    $connResult = "requestsPerSec=$requestsPerSec meanConnectionTime_ms=$meanConnectionTime_ms"

                    $metadata = "Concurrency=$testConcurrency"
                    $currentTestResult.TestSummary += New-ResultSummary -testResult $connResult -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                    if (([float]$requestsPerSec -eq 0)) {
                        $uploadResults = $false
                        $testResult = "FAIL"
                    }
                } catch {
                    $ErrorMessage = $_.Exception.Message
                    $ErrorLine = $_.InvocationInfo.ScriptLineNumber
                    Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
                    $currentTestResult.TestSummary += New-ResultSummary -testResult "Error in parsing logs." -metaData "Apache" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                }
            }
        } elseif ($currentTestData.testName -imatch "PERF-MEMCACHED-BENCHMARK") {
            foreach ($line in $ReportLog) {
                if ($line -imatch "TestConnections") {
                    continue;
                }
                try {
                    $TestConnections = ($line.Trim() -Replace " +"," ").Split(" ")[0]
                    $AverageLatency_ms = ($line.Trim() -Replace " +"," ").Split(" ")[6]
                    $AverageOpsPerSec = ($line.Trim() -Replace " +"," ").Split(" ")[9]
                    $connResult = "AverageLatency_ms=$AverageLatency_ms AverageOpsPerSec=$AverageOpsPerSec"

                    $metadata = "TestConnections=$TestConnections"
                    $currentTestResult.TestSummary += New-ResultSummary -testResult $connResult -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                    if (([float]$AverageOpsPerSec -eq 0)) {
                        $uploadResults = $false
                        $testResult = "FAIL"
                    }
                } catch {
                    $ErrorMessage = $_.Exception.Message
                    $ErrorLine = $_.InvocationInfo.ScriptLineNumber
                    Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
                    $currentTestResult.TestSummary += New-ResultSummary -testResult "Error in parsing logs." -metaData "memcached" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                }
            }
        }
        #endregion

        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        } elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        } elseif (($finalStatus -imatch "TestCompleted") -and $uploadResults) {
            $testResult = "PASS"
        } elseif ($finalStatus -imatch "TestRunning") {
            Write-LogInfo "Powershell background job is completed but VM is reporting that test is still running. Please check $LogDir\ConsoleLogs.txt"
            Write-LogInfo "Contents of summary.log : $testSummary"
            $testResult = "PASS"
        }

        $DataCsv = Import-Csv -Path $LogDir\report.csv
        Write-LogInfo ("`n**************************************************************************`n"+$CurrentTestData.testName+" RESULTS...`n**************************************************************************")
        Write-Host ($DataCsv | Format-Table * | Out-String)

        $LogContents = Get-Content -Path "$LogDir\report.log"
        $TestDate = $(Get-Date -Format yyyy-MM-dd)
        if ($testResult -eq "PASS") {
            $TestCaseName = $GlobalConfig.Global.$TestPlatform.ResultsDatabase.testTag
            if (!$TestCaseName) {
                $TestCaseName = $CurrentTestData.testName
            }
            $HostOs =  $(Get-Content "$LogDir\VM_properties.csv" | Select-String "Host Version"| ForEach-Object{$_ -replace ",Host Version,",""})
            $GuestDistro = $(Get-Content "$LogDir\VM_properties.csv" | Select-String "OS type"| ForEach-Object{$_ -replace ",OS type,",""})
            $KernelVersion = $(Get-Content "$LogDir\VM_properties.csv" | Select-String "Kernel version"| ForEach-Object{$_ -replace ",Kernel version,",""})
            Write-LogInfo "Generating the performance data for database insertion"
            for ($i = 1; $i -lt $LogContents.Count; $i++) {
                $Line = $LogContents[$i].Trim() -split '\s+'
                $resultMap = @{}
                $resultMap["TestCaseName"] = $TestCaseName
                $resultMap["TestDate"] = $TestDate
                $resultMap["HostType"] = $TestPlatform
                $resultMap["HostBy"] = $CurrentTestData.SetupConfig.TestLocation
                $resultMap["HostOS"] = $HostOs
                $resultMap["GuestOS"] = $GuestDistro
                $resultMap["InstanceSize"] = $clientVMData.InstanceSize
                $resultMap["KernelVersion"] = $KernelVersion
                $resultMap["DataPath"] = $DataPath
                if ($currentTestData.testName -imatch "PERF-APACHE-BENCHMARK") {
                    $resultMap["WebServerVersion"] = $($Line[0])
                    $resultMap["TestConcurrency"] = [Decimal]$($Line[1])
                    $resultMap["NumberOfAbInstances"] = [Decimal]$($Line[2])
                    $resultMap["ConcurrencyPerAbInstance"] = [Decimal]$($Line[3])
                    $resultMap["Document_bytes"] = [Decimal]$($Line[4])
                    $resultMap["CompleteRequests"] = [Decimal]$($Line[5])
                    $resultMap["RequestsPerSec"] = [Decimal]$($Line[6])
                    $resultMap["TransferRate_KBps"] = [Decimal]$($Line[7])
                    $resultMap["MeanConnectionTimes_ms"] = [Decimal]$($Line[8])
                } elseif ($currentTestData.testName -imatch "PERF-MEMCACHED-BENCHMARK") {
                    $resultMap["TestConnections"] = [Decimal]$($Line[0])
                    $resultMap["Threads"] = [Decimal]$($Line[1])
                    $resultMap["ConnectionsPerThread"] = [Decimal]$($Line[2])
                    $resultMap["RequestsPerThread"] = [Decimal]$($Line[3])
                    $resultMap["BestLatency_ms"] = [Decimal]$($Line[4])
                    $resultMap["WorstLatency_ms"] = [Decimal]$($Line[5])
                    $resultMap["AverageLatency_ms"] = [Decimal]$($Line[6])
                    $resultMap["BestOpsPerSec"] = [Decimal]$($Line[7])
                    $resultMap["WorstOpsPerSec"] = [Decimal]$($Line[8])
                    $resultMap["AverageOpsPerSec"] = [Decimal]$($Line[9])
                }
                $currentTestResult.TestResultData += $resultMap
            }
        }
        Write-LogInfo "Test result : $testResult"
    } catch {
        $ErrorMessage = $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
    } finally {
        $metaData = "${testName} RESULT"
        if (!$testResult) {
            $testResult = "Aborted"
        }
        $resultArr += $testResult
    }

    $currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
    return $currentTestResult
}

Main -TestParams (ConvertFrom-StringData $TestParams.Replace(";","`n")) -AllVMData $AllVmData
