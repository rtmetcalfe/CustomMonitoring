###########################################################################################
# Filename:		GetSANStatus.PS1
# Description:	This script retrieves performance metrics and array health from an
#               IBM / Dell / LSI SAN Array
# Created by:	Jon Czerwinski, Cohn Consulting Corporation,
#               based on work by Christian Joy, Intellect Information Technology
# Date:			Jul 18, 2012
# Version       1.1
###########################################################################################
   			

# Version History
# 1.0 - Initial release (20120206)
# 1.1 - Corrected how the health status is parsed (20120718)

#################################################
# Retrieve the SAN Name from the command line   #
#################################################
param([string]$SanName)

#########################################
# Hey! YOU NEED TO MODIFY THESE VALUES! #
#########################################
$ParentClass = "NCentral"
$SubClass = $ParentClass + "_SANStatus"

#################################################
# The values below vary depending on whether    #
# the SAN is an IBM, Dell, or (possibly) LSI    #
# Uncomment the variable assigments for your    #
# brand.                                        #
#################################################
#################################################
# Common values                                  #
#################################################
$interval = 30

#################################################
# Determine Program root path                   #
#################################################
If (test-path "env:ProgramFiles(x86)") {
    $ProgFile = (dir 'env:ProgramFiles(x86)').Value
    } else {
    $ProgFile = (dir 'env:ProgramFiles').Value
    }

#################################################
# Dell values                                   #
#################################################
$smcli = $ProgFile + "\Dell\MD Storage Software\MD Storage Manager\client\smcli.exe"
$PerfCmd = "set performanceMonitor interval=" + $interval + " iterations=1; show allvirtualdisks performancestats;"
$HealthCmd = "show storageArray healthStatus;"
$HealthOptimalStatus = "Storage array health status = optimal."

#################################################
# IBM values                                   #
#################################################
#$smcli = $ProgFile + "\IBM_DS\Client\smcli.exe"
#$PerfCmd = "set performanceMonitor interval=" + $interval + " iterations=1; show alllogicaldrives performancestats;"
#$HealthCmd = "show storageSubsystem healthstatus;"
#$HealthOptimalStatus = "Storage Subsystem health status = optimal."



###########################################################################################
# Check to make sure that the ExecutionPolicy for Powershell isn't set to 'Restricted'    #
###########################################################################################
$CurrentPolicy = Get-ExecutionPolicy
If ($CurrentPolicy -eq 'Restricted')
    {
        WRITE-HOST "The current execution policy is set to $CurrentPolicy - this is a bad thing!"
        WRITE-HOST "I'll try to set the execution policy to 'RemoteSigned' - just a sec."
        SET-EXECUTIONPOLICY RemoteSigned
        RETURN
    }

#################################################
# Test for and, if necessary, create		    #
# the custom WMI classes            	        #
#################################################
$tc = ([wmiclass]"\root\cimv2").getsubclasses() | where {$_.Name -eq $SubClass}	
if ($tc -eq $null) {
	$class = new-object wmiclass ("root\cimv2", [String]::Empty, $null)
	$class["__Class"] = $ParentClass
	$class.Qualifiers.Add("Static", $true)
	$rc = $class.Put()

	[wmiclass]$sc = $class.derive($SubClass)
	$sc.Qualifiers.Add("Static", $false)
	$sc.Properties.Add("ArrayName", [System.Management.CimType]::String, $false)
	$sc.Properties["ArrayName"].Qualifiers.Add("Key", $true)
    $sc.Properties.Add("ReadPct", [System.Management.CimType]::UInt64, $false)
	$sc.Properties["ReadPct"].Qualifiers.Add("Normal", $true)    
    $sc.Properties.Add("CacheHitPct", [System.Management.CimType]::UInt64, $false)
	$sc.Properties["CacheHitPct"].Qualifiers.Add("Normal", $true)    
    $sc.Properties.Add("KBSecond", [System.Management.CimType]::Real32, $false)
	$sc.Properties["KBSecond"].Qualifiers.Add("Normal", $true)    
    $sc.Properties.Add("IOSecond", [System.Management.CimType]::Real32, $false)
    $sc.Properties["IOSecond"].Qualifiers.Add("Normal", $true)    
	$sc.Properties.Add("HealthOptimal", [System.Management.CimType]::Boolean, $false)
	$sc.Properties["HealthOptimal"].Qualifiers.Add("Normal", $true)
    $sc.Properties.Add("HealthError", [System.Management.CimType]::String, $false)
    $sc.Properties["HealthError"].Qualifiers.Add("Normal", $true)
	$sc.Properties.Add("LastUpdate", [System.Management.CimType]::UInt64, $false)
	$sc.Properties["LastUpdate"].Qualifiers.Add("Normal", $true)
	
    $rc = $sc.put()
	}
	
###############################################################
# Loop through and remove existing instances                  #
###############################################################
$WMIarray = gwmi $SubClass
if ($WMIarray) {
    $WMIarray | % {
        if ($_.ArrayName.StartsWith($SanName)) {
            $_ | Remove-WMIObject
            }
        }
    }

###############################################################
# Retrieve Performance Statistics from SAN                    #
###############################################################
Write-Host ""
Write-Host "Pulling performance data from" $SanName
Write-Host $Interval "second sample."

$PerfData = &$SMCLI "-n" $SanName "-c" `"$perfcmd`" "-S"

$PerfData = $PerfData -notmatch "Performance Monitor Statistics for Storage"
$PerfData = $PerfData -notmatch "Capture Iterati"
$PerfData = $PerfData -notmatch "Date/Time"
$PerfData = $PerfData -notmatch "^$"
$PerfData = $PerfData -match ","
$PerfData = $PerfData -replace '/',''
$PerfData[0] = $PerfData[0] -replace ' ',''
$PerfData = ($PerfData | ConvertFrom-CSV)

Write-Host ""
$PerfData | fl

###############################################################
# Retrieve Health Status from SAN                             #
###############################################################
Write-Host ""
Write-Host "Pulling health status from" $SanName

$HealthError = ""
$HealthData = &$SMCLI "-n" $SanName "-c" `"$healthcmd`" "-S"

$Optimal = ([string]::Compare($HealthOptimalStatus, $HealthData, $True) -ne -1)

if (-not $Optimal) {
    $HealthError = $HealthData[1]
    $HealthData = $HealthData[2..($HealthData.count -1)]
    $vDisks = $HealthData -match "Virtual Disk"
    $vDisks = ([System.String]$vDisks).substring(([System.String]$vDisks).IndexOf(": ")+2)
    $vDisks = $vDisks -replace ' ',''
    $vDisks = $vDisks.Split(',')
    }
    
Write-Host ""
$HealthData | fl

###############################################################
# Update each non-optimal virtual disk with error info        #
###############################################################
foreach ($item in $PerfData) {
    $item | add-member NoteProperty HealthError ""
    $item | add-member NoteProperty Optimal $true
    foreach ($vDisk in $vDisks) {
        if ($vDisk -eq ($item.storagearrays -replace 'Virtual Disk ','')) {
            $item.Optimal = $false
            $item.HealthError = $HealthError
            break
            }
        }
    }

###############################################################
# Iterate through the virtual disks and create WMI instances  #
###############################################################
$PerfData | % {
    $Now = [DateTime]::Now
    $vDisk = ([wmiclass]$SubClass).CreateInstance()
    $vDisk.ArrayName = $SanName + ' - ' + $_.StorageArrays
    $vDisk.ReadPct = [Math]::Round($_.ReadPercentage)
    $vDisk.CacheHitPct = [Math]::Round($_.CacheHitPercentage)
    $vDisk.KBSecond = [Decimal]$_.CurrentKBSecond * 1KB
    $vDisk.IOSecond = [Decimal]$_.CurrentIOSecond
    $vDisk.HealthOptimal = $_.Optimal
    $vDisk.HealthError = $_.HealthError     
    $vDisk.LastUpdate = $Now.Ticks
        
    $rc = $vDisk.Put()
	}
