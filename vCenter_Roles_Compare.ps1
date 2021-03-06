<#        
    .SYNOPSIS
     A brief summary of the commands in the file.

    .DESCRIPTION
    A detailed description of the commands in the file.

    .NOTES
    ========================================================================
         Windows PowerShell Source File 
         
         NAME: vCenter_Roles_Compare.ps1
         
         AUTHOR: Jason Foy
         DATE  : 5-JUL-2019
         
         COMMENT: Uses a single vCenter for baseline and report any deviation in Role values across a set of vCenter instances
         
    ==========================================================================
#>
Clear-Host
# ==============================================================================================
# ==============================================================================================
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
function Exit-Script{
	Write-Host "Script Exit Requested, Exiting..."
	Stop-Transcript
	exit
}
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
function Get-PowerCLI{
	$pCLIpresent=$false
	Get-Module -Name VMware.VimAutomation.Core -ListAvailable | Import-Module -ErrorAction SilentlyContinue
	try{$pCLIpresent=((Get-Module VMware.VimAutomation.Core).Version.Major -ge 10)}
	catch{}
	return $pCLIpresent
}
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

if(!(Get-PowerCLI)){Write-Host "* * * * No PowerCLI Installed or version too old. * * * *" -ForegroundColor Red;Exit-Script}
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$Version = "1.1.0"
$ScriptName = $MyInvocation.MyCommand.Name
$scriptPath = Split-Path $MyInvocation.MyCommand.Path
$CompName = (Get-Content env:computername).ToUpper()
$userName = ($env:UserName).ToUpper()
$userDomain = ($env:UserDomain).ToUpper()
$StartTime = Get-Date
$Date = Get-Date -Format g
$dateSerial = Get-Date -Format yyyyMMddhhmmss
Write-Host ("="*80) -ForegroundColor DarkGreen
Write-Host ""
Write-Host `t`t"$scriptName v$Version"
Write-Host `t`t"Started $Date"
Write-Host ""
Write-Host ("="*80) -ForegroundColor DarkGreen
Write-Host ""
$logsfolder = Join-Path -Path $scriptPath -ChildPath "Logs"
$traceFile = Join-Path -Path $logsfolder -ChildPath "$ScriptName.trace"
if(!(Test-Path $logsfolder)){New-Item -Path $logsfolder -ItemType Directory|Out-Null}
Start-Transcript -Force -LiteralPath $traceFile
$configFile = Join-Path -Path $scriptPath -ChildPath "config.xml"
if(!(Test-Path $configFile)){Write-Host "! ! ! Missing CONFIG.XML file ! ! !";Exit-Script}
[xml]$XMLfile = Get-Content $configFile -Encoding UTF8
$RequiredConfigVersion = "1"
if($XMLFile.Data.Config.Version -lt $RequiredConfigVersion){Write-Host "Config version is too old!";Exit-Script}
$ReportFolder = Join-Path -Path $scriptPath -ChildPath "Reports"
if(!(Test-Path $ReportFolder)){New-Item -Path $ReportFolder -ItemType Directory|Out-Null}
$ReportFile = Join-Path -Path $ReportFolder -ChildPath "$dateSerial-vCenterRoleConsistency.html"
$reportTitle = "ROLES $($XMLFile.Data.Config.ReportTitle.value)"
$DEV_MODE=$false;if($XMLFile.Data.Config.DevMode.value -eq "TRUE"){$DEV_MODE=$true;Write-Host "DEV_MODE ENABLED" -ForegroundColor Green}else{Write-Host "DEV_MODE DISABLED" -ForegroundColor red}
if($DEV_MODE){
	$vCenterFile = $XMLFile.Data.Config.vCenterList_TEST.value
	$FROM = $XMLFile.Data.Config.FROM_TEST.value
	$TO = $XMLFile.Data.Config.TO_TEST.value
	$reportTitle = "DEV $reportTitle"
}
else{
	$vCenterFile = $XMLFile.Data.Config.vCenterList.value
	$FROM = $XMLFile.Data.Config.FROM.value
	$TO = $XMLFile.Data.Config.TO.value
}
if(Test-Path $vCenterFile){
	Write-Host "Using vCenter List:" -NoNewline;Write-Host $vCenterFile -ForegroundColor Cyan
	$vCenterList = Import-Csv $vCenterFile -Delimiter ","|Sort-Object	CLASS,LINKED,NAME
	$vCenterCount = $vCenterList.Count	
}
else{Write-Host "No vCenter List Found" -ForegroundColor Red -NoNewline;Write-Host "[" -NoNewline;write-host $vCenterFile -NoNewline;Write-Host "]";Exit-Script}
$sendMail = $false;if($XMLFile.Data.Config.SendMail.value -eq "TRUE"){$sendMail=$true;Write-Host "SENDMAIL ENABLED" -ForegroundColor Green}else{Write-Host "SENDMAIL DISABLED" -ForegroundColor red}
$SMTP = $XMLFile.Data.Config.SMTP.value
$subject = "$reportTitle $(Get-Date -Format yyyy-MMM-dd)"
$ReferenceHostName = $XMLFile.Data.Config.RoleAuditReferenceInstance.value
$loggedIN = $false
Write-Host "Connecting to $vCenterCount vCenter Instances..." -ForegroundColor Cyan
$vCenterList|ForEach-Object{
	$vConn=""
	$vConn = Connect-VIServer $_.Name -Credential (New-Object System.Management.Automation.PSCredential $_.ID, (ConvertTo-SecureString $_.Hash)) -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
	if($vConn){Write-Host $_.Name -ForegroundColor Green;$loggedIN=$true}
	else{Write-Host	$_.Name -ForegroundColor Red -NoNewline;Write-Host	" Login Failed!" -ForegroundColor Yellow}
}
$connectedvCenters = $global:defaultviservers.count
Write-Host "Connected to " -NoNewline;Write-Host $connectedvCenters -ForegroundColor Cyan -NoNewline;Write-Host " vCenter instances." -NoNewline
if ($loggedIN){
	Write-Host "[" -NoNewline;Write-Host "OK" -ForegroundColor Green -NoNewline;Write-Host "]"
	Write-Host "Using $ReferenceHostName for baseline"
	$ReferenceHost = $global:defaultviservers|Where-Object{$_.Name -like $ReferenceHostName+"*"}
	Write-Host "Collecting VI Roles..."
	$RoleSet = Get-VIRole
	Write-Host "Unique Roles:" ($RoleSet|Select-Object -Unique).Count
	$StatusTable = @()
	$roleNames = $RoleSet|Sort-Object Name|Select-Object Name -Unique
	Write-Host "Scanning Roles..."
	foreach ($viRole in $roleNames){
		if(!($viRole.Name -eq "NoAccess")){
			# Write-Host "viRole: $($viRole.Name)" -ForegroundColor Yellow
			$refRoleCount = ($RoleSet|Where-Object{($_.Name -eq $viRole.Name) -and ($_.Server -like $ReferenceHost)}).Count
			$refRoleCheck = $RoleSet|Where-Object{($_.Name -eq $viRole.Name) -and (!($_.Server -like $ReferenceHost))}
			if(($refRoleCount -eq 0) -and ($refRoleCheck.Count -lt 2)){
	# 			Write-Host "refRoleCheck.server::"$refRoleCheck.Server
				$thisReferenceHost = $global:defaultviservers|Where-Object{$_.Name -like $refRoleCheck.Server}
			}
			elseif(($refRoleCount -eq 0) -and ($refRoleCheck.Count -gt 1)){
				$thisRoleCheckSet = $RoleSet|Where-Object{($_.Name -eq $viRole.Name) -and (!($_.Server -like $ReferenceHost))}
				$refSearchString=(($thisRoleCheckSet|Select-Object -First 1).Server).ToString()+"*"
				$thisReferenceHost = $global:defaultviservers|Where-Object{$_.Name -like $refSearchString}
			}
			else{$thisReferenceHost = $ReferenceHost}
			# Write-Host " RefHost: $($thisReferenceHost)" -ForegroundColor Yellow
			$thisReferenceObject = $RoleSet|Where-Object{($_.Name -eq $viRole.Name) -and ($_.Server -like $thisReferenceHost)}
			
			# if($thisReferenceObject){Write-Host $thisReferenceObject.Name $thisReferenceObject.Server -ForegroundColor Yellow}
			
			$row = New-Object psobject
			$row|Add-Member -MemberType NoteProperty -Name "ROLE" -Value $viRole.Name
			foreach($VIserver in $vCenterList){
				if($VIserver.Name -like $thisReferenceHost){$thisTestValue = "REFHOST"}
	# 			elseif($thisReferenceHost -eq "REFHOST"){$thisTestValue = "SOLO"}
				else{
					$thisDifferenceObject = $RoleSet|Where-Object{($_.Name -eq $viRole.Name) -and ($_.Server -like $VIserver.Name)}
					if($null -ne $thisDifferenceObject){
						$thisTestResult = Compare-Object -ReferenceObject $thisReferenceObject.PrivilegeList -DifferenceObject $thisDifferenceObject.PrivilegeList -ErrorAction SilentlyContinue
						if($null -eq $thisTestResult){$thisTestValue = "CONSISTENT"}
						else{$thisTestValue = "DELTA"}
					}
					else{$thisTestValue = "MISSING"}
				}
				$row|Add-Member -MemberType NoteProperty -Name $VIserver.Name -Value $thisTestValue
	# 			Write-Host	$VIserver.Name $thisDifferenceObject.Name $thisTestValue -ForegroundColor Magenta
				$thisDifferenceObject = $null
			}
			$StatusTable+=$row
		}
	}
	Write-Host "Prepping Report..."
	$nameHash = @{}
	$nameHash.Add("Label","ROLE")
	$nameString="ROLE";foreach($VIserver in $vCenterList){$nameString+=","+$VIserver.Name;}
$htmlHead=@"
<style type="text/css">
body{font-family:calibri;font-size:10pt;font-weight:normal;color:black;}
th{text-align:center;background-color:#00417c; color:#FFFFFF; font-weight:bold;font-size:12px;}
td{background-color:#F5F5F5;font-weight:normal; font-size:10px; padding: 3px 10px 3px 10px;}
.clRed{background-color:MistyRose; font-weight:bold;color:Red;text-align: center;}
.clGreen{background-color:HoneyDew; font-weight:normal;color:DarkGreen;text-align:center;}
.clGold{background-color:LemonChiffon;font-weight:bold; color:GoldenRod;text-align: center;}
.clPurple{background-color:Lavender; font-weight:bold; color:DarkOrchid;text-align: center;}
</style>
"@
	$tableHTML = $StatusTable|Select-Object *|ConvertTo-Html -Head $htmlHead -Body "<h2> Role Consistency Audit </h2>" -PostContent "<hr><span style=""background-color:White; font-weight:normal; font-size:10px;color:Orange;align:right""><blockquote>v$Version - $CompName : $userName @ $userDomain - $StartTime</blockquote></span>"
	$tableHTML = $tableHTML.Replace("<td>CONSISTENT</td>","<td class=""clGreen"">CONSISTENT</td>")
	$tableHTML = $tableHTML.Replace("<td>MISSING</td>","<td class=""clGold"">MISSING</td>")
	$tableHTML = $tableHTML.Replace("<td>DELTA</td>","<td class=""clRed"">DELTA</td>")
	$tableHTML = $tableHTML.Replace("<td>REFHOST</td>","<td class=""clPurple"">REFHOST</td>")
	Write-Host "Writing report:" -NoNewline;Write-Host $ReportFile -ForegroundColor Cyan
	$tableHTML|Out-File -FilePath $ReportFile
	$tableHTML|ForEach-Object{$tableString+=$_}
# 	$tableString = $tableHTML.ToString()
	Write-Host "Disconnecting vCenter Instances..."
	Disconnect-VIServer $vConn -Confirm:$false
	if($sendMail){
		Write-Host "Emailing Report..."
		Send-MailMessage -Subject $subject -From $FROM -To $TO -Body $tableString -BodyAsHtml -SmtpServer $SMTP
	}
}
else{Write-Host "[" -NoNewline;Write-Host "ERROR" -ForegroundColor Red -NoNewline;Write-Host "]"}
# ==============================================================================================
# ==============================================================================================
$stopwatch.Stop()
$Elapsed = [math]::Round(($stopwatch.elapsedmilliseconds)/1000,1)
Write-Host ("="*80) -ForegroundColor DarkGreen
Write-Host ("="*80) -ForegroundColor DarkGreen
Write-Host ""
Write-Host "Script Completed in $Elapsed second(s)"
Write-Host ""
Write-Host ("="*80) -ForegroundColor DarkGreen
Exit-Script