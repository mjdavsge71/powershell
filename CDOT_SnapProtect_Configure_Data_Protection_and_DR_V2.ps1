@"
===============================================================================
Title: 		CDOT_SnapProtect_Configure_Data_Protection_and_DR_v2.ps1
Description: 	Set up voloume(s) data protection with SnapMirrors in SnapProtect 
Requirements: 	Windows Powershell and the Netapp Powershell Toolkit
Author: 	Matthew Savage
Version:        V2.1
Changes:
11/11/2015 - Matthew Savage:  Changed script to accomidate changes due to v10 SP 11
                              Switched from qmodify to qoperation for policy to subclient association
			      Added in additional variables to accomidate difference between sites
			      Added additional arguments to Invoke-Command statements for compatibility with Remote Sites
		
===============================================================================
"@
Import-Module DataONTAP
Write-Host "`nINSTRUCTIONS: Please only use this script for protecting volumes on the Springfield CDOT clusters. Don't forget to set the SnapMirror schedule in the SnapProtect admin console after your done.`n"
## Populate this file with the volume names you want to protect can be removed and parameter passed through WFA
$inputvolume = "S:\MTS_STORAGE\Scripts\Powershell\SnapProtect\SP_Volume_Protection_Input.txt"
Write-Host "IMPORTANT: Make sure the volume(s) you want to protect are added and SAVED to the  text file that just opened before continuing.`n"
& $inputvolume
## Add the Prod SVM name and cluster below
$prodcluster = Read-Host "Enter the Production CDOT Cluster Name: ie. MTSL1NTAPC02 (no suffix)"
$prodsvm = Read-Host "Enter Production CDOT SVM Name: ie. HL112L1SANC02"
# Pulling in NetApp credentials
$netappcreds = Get-Credential -Message "Enter your NetApp Credentials for $prodcluster"
#Sets the OCUM server instance
$ocum = "MTSSPRDFM14.mts.ln"
# Convert NetApp Array name to SP Friendly Client Name, setup default commserve, media agent, disk library
switch ($prodcluster)
    {
        "MTSL1NTAPC01" {$spclustnm = "MTSL1NTAPC01-SPR-CDOT";$commsrv = "mtsl1spc01";$cmdpath ="e:\cli";$SPMA = "MTSL1SPV01-SPR-VSA";$SPSP = "MTSL1SPV01";$SPDL = "DL_MTSL1SPV01_Network"}
        "MTSL1NTAPC02" {$spclustnm = "MTSL1NTAPC02-SPR-CDOT-ENCR";$commsrv = "mtsl1spc01";$cmdpath ="e:\cli";$SPMA = "MTSL1SPV01-SPR-VSA";$SPSP = "MTSL1SPV01";$SPDL = "DL_MTSL1SPV01_Network"}
        "MTSL3NTAPC01" {$spclustnm = "MTSL3NTAPC01-SCO-CDOT" ;$commsrv = "mtsl3spc01";$cmdpath ="d:\cli";$SPMA = "MTSL3SPV01-SCO-VSA";$SPSP = "MTSL2SPV01";$SPDL = "DL_MTSL3SPV01_Local"}
        "MTSL5NTAPC01" {$spclustnm = "MTSL5NTAPC01-RED-CDOT" ;$commsrv = "mtsl5spc01";$cmdpath ="d:\cli";$SPMA = "MTSL5SPV01-RED-VSA";$SPSP = "MTSL5SPV01";$SPDL = "DL_MTSL5SPV01_Local"}
        default {Write-Host "Warning!!!! Wrong Cluster Name only supports MTSL1NTAPC01 or MTSL1NTAPC02"
                return
                }
    }
$volumes = (Get-Content -Path $inputvolume)
Try
{
Write-Host "Attempting to connect to $prodcluster"
connect-nccontroller -name $prodcluster -credential $netappcreds
}
Catch
{
[NetApp.Ontapi.NaAuthException]
"`nWarning: You didn't provide the correct NetApp Credentials run the script again"
return
}
# Connecting to CommServe to execute commands, change user and password
        Write-Host "Connecting to $commsrv to execute commands"
        Invoke-Command -computername $commsrv -scriptblock{
            cd $args[0]
            qlogin.exe -csn $args[1] -u admin -clp L3ft41ght
            } -argumentlist $cmdpath, $commsrv
            

ForEach ($vol in $volumes){
        $randSnapschedday = Get-Random -Input "00", "05"
        $randomSnapsched = Get-Random -Input "00", "05", "10", "15"
        # SMsched is a work in progress...not being invoked in this version of the script
        $randomSMsched = Get-Random -Input "00", "05", "10", "15", "20", "25", "30", "35", "40", "45", "50", "55"
        $contentpath = "'/" + $prodsvm + "/" + $vol + "'"
        #Creating Subclient
        Invoke-Command -computername $commsrv -scriptblock {
            cd $args[3]
            qoperation execute -af create_subclient_template.xml -appName NAS -clientName $args[0] -subclientName $args[1] -enableBackup true -numberOfBackupStreams 2 -dataBackupStoragePolicy/storagePolicyName Template_Policy -contentOperationType ADD -content/path $args[2]
        } -argumentlist $spclustnm,$vol,"$contentpath", $cmdpath
        #Creating Storage Policy NOTE CHANGE IF CHANGING MA LISTED ABOVE **********************
        $storagepol = $prodcluster + "_" + $SPSP + "_" + $vol
        Invoke-Command -computername $commsrv -scriptblock {
            qcreate sp -cs $args[0] -sp $args[1] -m $args[2] -l $args[3] -dfmservername $args[4]
        } -argumentlist $commsrv, $storagepol, $SPMA, $SPDL, $ocum
        #Add storage Policy to Subclient
        Invoke-Command -computername $commsrv -scriptblock {
            cd $args[3]
            qoperation execute -af reassociateMultipleSubclients.xml -storagePolicyName $args[0] -clientName $args[1] -appName NAS -backupsetName defaultBackupSet -s $args[2]
        } -argumentlist $storagepol, $spclustnm, $vol, $cmdpath
        #Set basic retention on storage policy
        Invoke-Command -computername $commsrv -scriptblock {
            SetRetentionTime -sp $args[0] -copy ALL -days 1 -cycles 0
        } -argumentlist $storagepol
        #Set extended retention on storage policy
        Invoke-Command -computername $commsrv -scriptblock {
            cd $args[1]
            qoperation execute -af Update_extendedRetention.xml -storagePolicyName $args[0] -copyName 'Primary(Snap)' -extendedRetentionRuleOne/isenabled 1 -extendedRetentionRuleOne/endDays 30 -extendedRetentionRuleOne/rule 'EXTENDED_DAY'
        } -argumentlist $storagepol, $cmdpath
        #Starting Schedule Assignment
        $spsched = $prodcluster.ToUpper() + "_Snapshot_Every_1H_" + $randomsnapsched
        $spschedday = $prodcluster.ToUpper() + "_Snapshot_Daily_" + $randsnapschedday
        $spsqlnone = $prodcluster.ToUpper() + "_Snapshot_SQL_None"
        #Create SnapMirror
        if($prodcluster -like "MTSL1NTAPC02"){
                Invoke-Command -computername mtsl1spc01.mts.ln -scriptblock {
                qoperation execute -af e:\cli\sp_copycreation.xml -storagePolicyName $args[0] -copyName SnapMirror -libraryName DL_MTSL1SPV01_Network -mediaAgentName mtsl1spv01-SPR-VSA -resourcePoolsList/operation 'ADD' -resourcePoolsList/resourcePoolName 'SnapMirror L2 Encrypted SAS Pool' -provisioningPolicyName 'SnapMirror Destination' -sourceCopy/copyName 'Primary(Snap)' -isSnapCopy 1 -isMirrorCopy 1
                } -argumentlist $storagepol
            }
         if($prodcluster -like "MTSL1NTAPC01"){
                    if($vol -like "*SAN*" -or $vol -like "*SQL*"){
                            Invoke-Command -computername mtsl1spc01.mts.ln -scriptblock {
                            qoperation execute -af e:\cli\sp_copycreation.xml -storagePolicyName $args[0] -copyName SnapMirror -libraryName DL_MTSL1SPV01_Network -mediaAgentName mtsl1spv01-SPR-VSA -resourcePoolsList/operation 'ADD' -resourcePoolsList/resourcePoolName 'SnapMirror L2 SAS Pool' -provisioningPolicyName 'SnapMirror Destination' -sourceCopy/copyName 'Primary(Snap)' -isSnapCopy 1 -isMirrorCopy 1
                            } -argumentlist $storagepol
                        }else{
                            Invoke-Command -computername mtsl1spc01.mts.ln -scriptblock {
                            qoperation execute -af e:\cli\sp_copycreation.xml -storagePolicyName $args[0] -copyName SnapMirror -libraryName DL_MTSL1SPV01_Network -mediaAgentName mtsl1spv01-SPR-VSA -resourcePoolsList/operation 'ADD' -resourcePoolsList/resourcePoolName 'SnapMirror L2 SATA Pool' -provisioningPolicyName 'SnapMirror Destination' -sourceCopy/copyName 'Primary(Snap)' -isSnapCopy 1 -isMirrorCopy 1
                            } -argumentlist $storagepol
                        }
            }
        #This is the place for the SM scheduling code once I figure it out
        #Invoke-Command -computername mtsl1spc01.mts.ln -scriptblock {
        #qoperation execute -af ???????
        #} -argumentlist $storagepol

        #Discovering LUN name for New Naming Standard
        if ($vol -like "*L0*PS0*SAN*" -and $vol -notlike "*L0*PS0*CIFE*"){
            $luns = get-nclun -vserver $prodsvm -volume $vol
                if ($luns.Path -match "SQL"){
                    Write-Host $luns.Path "Matches SQL"
                    #Set Daily Schedule to NONE for SQL LUNs
                    Invoke-Command -computername $commsrv -scriptblock {
                    qmodify schedulepolicy -cs $args[3] -o add -scp $args[0] -c $args[1] -a Q_NAS -b defaultBackupSet -s $args[2]
                    } -argumentlist $spsqlnone, $spclustnm, $vol, $commsrv
                 }elseif ($luns.Path -match "BOOT"){
                          Write-Host $luns.Path "Matches BOOT"
                          #Set Daily Schedule for BOOT LUNs
                          Invoke-Command -computername $commsrv -scriptblock {
                          qmodify schedulepolicy -cs $args[3] -o add -scp $args[0] -c $args[1] -a Q_NAS -b defaultBackupSet -s $args[2]
                          } -argumentlist $spschedday, $spclustnm, $vol, $commsrv
                      }elseif ($luns.Path -notmatch "Boot" -and $luns.Path -notmatch "SQL"){
                            Write-Host $luns.Path "Not Matches BOOT or SQL"
                            #Set Daily Schedule for BOOT LUNs
                            Invoke-Command -computername $commsrv -scriptblock {
                            qmodify schedulepolicy -cs $args[3] -o add -scp $args[0] -c $args[1] -a Q_NAS -b defaultBackupSet -s $args[2]
                             } -argumentlist $spsched, $spclustnm, $vol, $commsrv
                        }
         }else{
             #Set daily subclient Schedule on all other volumes matching boot or archive 
             if ($vol -like "*boot*" -or $vol -like "*archive*"){
                    Write-Host $vol "Matches Boot or Archive"
                    #Set Daily Schedule for Boot Volumes
                    Invoke-Command -computername $commsrv -scriptblock {
                    qmodify schedulepolicy -cs $args[3] -o add -scp $args[0] -c $args[1] -a Q_NAS -b defaultBackupSet -s $args[2]
                    } -argumentlist $spschedday, $spclustnm, $vol, $commsrv
                }
             #Set No subclient Schedule on all SQL named volumes that don't alos contain boot
             if ($vol -like "*sql*" -and $vol -notlike "*boot*"){
                    Write-Host $vol "Matches SQL"
                    #Set Daily Schedule to NONE for SQL 
                    Invoke-Command -computername $commsrv -scriptblock {
                    qmodify schedulepolicy -cs $args[3] -o add -scp $args[0] -c $args[1] -a Q_NAS -b defaultBackupSet -s $args[2]
                    } -argumentlist $spsqlnone, $spclustnm, $vol, $commsrv
                }
              #Set subclient Schedule all other volumes that don't meet the conditions above
              if ($vol -notlike "*sql*" -and $vol -notlike "*boot*" -and $vol -notlike "*archive*"){
                    Write-Host $vol "Matches All Others"
                    #Set Daily Schedule for SQL Boot
                    Invoke-Command -computername $commsrv -scriptblock {
                    qmodify schedulepolicy -cs $args[3] -o add -scp $args[0] -c $args[1] -a Q_NAS -b defaultBackupSet -s $args[2]
                    } -argumentlist $spsched, $spclustnm, $vol, $commsrv
               }
        }

}
Write-Host "Logging out of $commsrv"
Invoke-Command -computername $commsrv -scriptblock {cd $args[0]; qlogout.exe -cs $args[1]} -ArgumentList $cmdpath, $commsrv
