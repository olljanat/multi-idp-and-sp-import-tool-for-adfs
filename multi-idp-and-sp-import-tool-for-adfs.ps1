# Settings:
$url = "https://www.example.com/metadata.xml"
$ExportIDPs = $True
$ExportSPs = $False
$PrefixText = "ABC - "
$TempFile = "$pwd\temp.xml"
$IDPEnabledByDefault = $False
$SPEnabledByDefault = $True
$IDPSignatureAlgorithm = "http://www.w3.org/2000/09/xmldsig#rsa-sha1"

# Workaround to add SingleLogoutService values to metadata because HAKA metadata does not contain that value
# and ADFS does not support claim based logout url
$IncludeCustomLogoutUrl = $True
$LogOutUrlCSV = $(Split-Path $script:MyInvocation.MyCommand.Path) + "\logout-url.csv"


# Code:
If (($IncludeCustomLogoutUrl -eq $True) -and (!(Test-Path $LogOutUrlCSV))) {
	throw "File: $LogOutUrlCSV does not exists"
}
$global:logouturls = Import-Csv $LogOutUrlCSV

Import-Module ADFS

$wc = New-Object System.Net.WebClient
$wc.Encoding = [System.Text.Encoding]::UTF8
[xml]$global:fullMetadata = $wc.downloadString($url)

Function Test-MetadataSignature ($Metadata) {
	# FixMe: Check signature
	# $Signature = $fullMetadata.EntitiesDescriptor.Signature.SignatureValue
	Return $True
}

Function Get-EntityIdentifier ($SourceEntity) {
	[xml]$xmlDocument = $SourceEntity.OuterXml
	$EntityIdentifier = $xmlDocument.EntityDescriptor.entityID
	Return $EntityIdentifier
}

Function Save-EntityToXMLFile ($SourceEntity, $TempFile, $EntityIdentifier) {
	If (Test-Path $TempFile) { Remove-Item -Path $TempFile -Confirm:$False }
	[xml]$xmlDocument = $SourceEntity.OuterXml
	Try {
		$xmlDocument.Save($TempFile)
	} Catch {
		Write-Warning "Saving XML file failed - Entity: $EntityIdentifier"
		Return $null
	}
}

Function Update-ClaimsProviderTrusts ($TempFile, $EntityIdentifier, $PrefixText) {
	$EntityName = $PrefixText + $EntityIdentifier
	Write-Host "Processing $EntityName"
	
	$ClaimsProviderTrust = Get-AdfsClaimsProviderTrust -Identifier $EntityIdentifier
	If ($ClaimsProviderTrust) {
		$ClaimsProviderTrust | Update-AdfsClaimsProviderTrust -MetadataFile $TempFile
	} Else {
		Add-AdfsClaimsProviderTrust -Name $EntityName -MetadataFile $TempFile -Enabled $IDPEnabledByDefault -SignatureAlgorithm $IDPSignatureAlgorithm
	}
}

Function Update-RelayingPartyTrusts ($TempFile, $EntityIdentifier, $PrefixText) {
	$EntityName = $PrefixText + $EntityIdentifier
	Write-Host "Processing $EntityName"
	
	$ADFSRelyingPartyTrust = Get-ADFSRelyingPartyTrust -Identifier $EntityIdentifier
	If ($ADFSRelyingPartyTrust) {
		$ADFSRelyingPartyTrust | Update-ADFSRelyingPartyTrust -MetadataFile $TempFile
	} Else {
		Add-ADFSRelyingPartyTrust -Name $EntityName -MetadataFile $TempFile -Enabled $SPEnabledByDefault
	}

}

Function Add-IDPSingleLogoutServiceURL ($IDPEntity, $EntityIdentifier) {
	$LogOutURL = $logouturls | Where-Object {$_.entityID -eq $EntityIdentifier}
	If ($LogOutURL) {
		$logout = $fullMetadata.CreateElement("SingleLogoutService","urn:oasis:names:tc:SAML:2.0:metadata")
		$logout.SetAttribute("Binding","urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect")
		$logout.SetAttribute("Location",$LogOutURL.'logout-url')
		$IDPEntity.IDPSSODescriptor.AppendChild($logout)
	}
}

$ValidSignature = Test-MetadataSignature $fullMetadata


If ($ValidSignature -eq $True) {
	$Entities = $fullMetadata.EntitiesDescriptor.EntityDescriptor

	If ($ExportIDPs -eq $True) {
		$IDPEntities = $Entities | Where-Object {$_.IDPSSODescriptor}
		ForEach ($IDPEntity in $IDPEntities) {
			$EntityIdentifier = Get-EntityIdentifier $IDPEntity
			If ($IncludeCustomLogoutUrl -eq $True) {
				Add-IDPSingleLogoutServiceURL $IDPEntity $EntityIdentifier
			}
			Save-EntityToXMLFile $IDPEntity $TempFile $EntityIdentifier
			If ($EntityIdentifier -ne $null) {
				Update-ClaimsProviderTrusts $TempFile $EntityIdentifier $PrefixText
			}
			Remove-Variable EntityIdentifier
		}
	}
	
	If ($ExportSPs -eq $True) {
		$SPEntities = $Entities | Where-Object {$_.SPSSODescriptor}
		ForEach ($SPEntity in $SPEntities) {
			$EntityIdentifier = Get-EntityIdentifier $IDPEntity
			Save-EntityToXMLFile $SPEntity $TempFile $EntityIdentifier
			If ($EntityIdentifier -ne $null) {
				Update-RelayingPartyTrusts $TempFile $EntityIdentifier $PrefixText
			}
			Remove-Variable EntityIdentifier
		}
	}
} Else {
	Write-Warning "Metadata signature is not valid"
}
