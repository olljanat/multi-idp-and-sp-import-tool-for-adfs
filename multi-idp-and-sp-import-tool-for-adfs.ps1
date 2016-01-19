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

$global:fullMetadata = New-Object System.Xml.xmlDocument
$fullMetadata.PreserveWhitespace = $true
$fullMetadata.Load($url)

Function Test-MetadataSignature {
	param (
		[xml]$xmlDocument
	)
	Add-Type -AssemblyName System.Security
	Add-Type @'
			public class RSAPKCS1SHA256SignatureDescription : System.Security.Cryptography.SignatureDescription
				{
					public RSAPKCS1SHA256SignatureDescription()
					{
						base.KeyAlgorithm = "System.Security.Cryptography.RSACryptoServiceProvider";
						base.DigestAlgorithm = "System.Security.Cryptography.SHA256Managed";
						base.FormatterAlgorithm = "System.Security.Cryptography.RSAPKCS1SignatureFormatter";
						base.DeformatterAlgorithm = "System.Security.Cryptography.RSAPKCS1SignatureDeformatter";
					}

					public override System.Security.Cryptography.AsymmetricSignatureDeformatter CreateDeformatter(System.Security.Cryptography.AsymmetricAlgorithm key)
					{
						System.Security.Cryptography.AsymmetricSignatureDeformatter asymmetricSignatureDeformatter = (System.Security.Cryptography.AsymmetricSignatureDeformatter)
							System.Security.Cryptography.CryptoConfig.CreateFromName(base.DeformatterAlgorithm);
						asymmetricSignatureDeformatter.SetKey(key);
						asymmetricSignatureDeformatter.SetHashAlgorithm("SHA256");
						return asymmetricSignatureDeformatter;
					}
				}
'@
	 $RSAPKCS1SHA256SignatureDescription = New-Object RSAPKCS1SHA256SignatureDescription
		[System.Security.Cryptography.CryptoConfig]::AddAlgorithm($RSAPKCS1SHA256SignatureDescription.GetType(), "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256")
	$SignedXML = New-Object System.Security.Cryptography.Xml.SignedXml -ArgumentList $xmlDocument

	$nsmgr = New-Object -TypeName System.Xml.XmlNamespaceManager -ArgumentList $xmlDocument.NameTable
	$nsmgr.AddNamespace("ds", "http://www.w3.org/2000/09/xmldsig#")
	$nodeList = $xmlDocument.SelectNodes("//ds:Signature", $nsmgr)
	$SignedXML.LoadXml($nodeList[0])
	$CheckSignature = $SignedXML.CheckSignature()
	
	return $CheckSignature
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

$ValidSignature = Test-MetadataSignature -xmlDocument $fullMetadata


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
