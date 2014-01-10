if (!(test-path function:gs)) { function gs() {} } # Get-Setting in Config

function HtmlDecode($html) {
    add-type -AssemblyName System.Web
    try {
        $html = [System.Web.HttpUtility]::HtmlDecode($html).Replace("`n","").Replace("`r","")
    } catch [exception] { <# Best Effort #> }
    return $html
}

function Query-Router($RouterName = (gs Router), $Page = 'Status_Lan.live', $Credential = $Credentials['Router']) {
    $web = Invoke-WebRequest "http://$RouterName/$Page.asp" -Credential $Credentials['Router']
    $matches = [regex]::Matches($web.Content, "`{(.*?)::(.*?)`}", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $ret = @{}
    foreach($m in $matches) {
        $ret.Add($m.Groups[1].Value.Replace("'",""), (HtmlDecode ($m.Groups[2].Value))) #.Replace("'","")).Trim())
    }
    return $ret
}

function Get-DHCPClients($RouterName = (gs Router), $Credential = $Credentials['Router']) {
    $data = (Query-Router -RouterName $RouterName -Page 'Status_Lan.live' -Credential $Credentials['Router']).dhcp_leases
    return Split-RouterValue $data @('HostName','IP','MAC','LeaseTime','!LastOctet')
}

function Get-ActiveClients($RouterName = (gs Router), $Credential = $Credentials['Router']) {
    $data = (Query-Router -RouterName $RouterName -Page 'Status_Lan.live' -Credential $Credentials['Router']).arp_table
    return Split-RouterValue $data @('HostName','IP','MAC','Usage')
}

function Get-VPNClients($RouterName = (gs Router), $Credential = $Credentials['Router']) {
    $data = (Query-Router -RouterName $RouterName -Page 'Status_Lan.live' -Credential $Credentials['Router']).pptp_leases
    return Split-RouterValue $data @('Interface', 'UserName', 'LANIP', 'RemoteIP', 'Unk')
}

function Get-WirelessClients($RouterName = (gs Router), $Credential = $Credentials['Router'], [switch]$ShowRawData=$false) {
    $data = (Query-Router -RouterName $RouterName -Page 'Status_Wireless.live' -Credential $Credentials['Router']).active_wireless
    if ($ShowRawData) { echo $data }
    return Split-RouterValue $data @('MAC', 'Interface', 'Uptime', 'TX', 'RX', 'Signal', 'Noise', '!Unk1', '!Unk2') | ? { $_.MAC.Count -gt 0 }
}

function Get-WirelessInfo($RouterName = (gs Router), $Credential = $Credentials['Router']) {
    $data = (Query-Router -RouterName $RouterName -Page 'Status_Wireless.live' -Credential $Credentials['Router'])
    return $data
}

function Get-LanInfo($RouterName = (gs Router), $Credential = $Credentials['Router']) {
    $data = (Query-Router -RouterName $RouterName -Page 'Status_Lan.live' -Credential $Credentials['Router'])
    return $data
}

function Get-WirelessSurvey($RouterName = (gs Router), $Credential = $Credentials['Router']) {
    $web = Invoke-WebRequest "http://$RouterName/Site_Survey.asp" -Credential $Credentials['Router']
    $m = [regex]::Matches($web.Content, "var table = new Array\((.*?)\);", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m.Success){
        $array = "[{0}]" -f $m.Groups[1].Value | ConvertFrom-Json
        return MapTo-Array $array @('SSID', 'Mode', 'MAC', 'Channel', 'Rssi', 'Noise', '!Beacon', 'Open', 'Opts', '!dtim', 'Rate')
    } else { Throw "Can't find wireless table data" }
}

function Get-RouterInfo($RouterName = (gs Router), $Credential = $Credentials['Router']) {
    $web = Invoke-WebRequest "http://$RouterName/Status_Router.asp" -Credential $Credentials['Router']
    return [PSCustomObject]@{
    'Name' =     Get-RegexRouterValue $web.Content "routername.*?iv>(.*?)</div"
    'Model' =    Get-RegexRouterValue $web.Content "sys_model.*?iv>(.*?)</div"
    'Firmware' = Get-RegexRouterValue $web.Content "sys_firmver.*?iv>(.*?)<\/div"
    'CPU' =      Get-RegexRouterValue $web.Content "cpu.*?iv>(.*?)</div"
    'Clock' =    Get-RegexRouterValue $web.Content "clock.*?`">(.*?)<\/span"
    }
}

function Get-RouterBandwidthInfo($GraphName = $null, $RouterName = (gs Router), $Credential = $Credentials['Router']) {
    $web = Invoke-WebRequest "http://$RouterName/Status_Bandwidth.asp" -Credential $Credentials['Router']
    $mx = [regex]::Matches($web.Content, "<h2>.*? - (.*?)</h2>.*?src=`"(.*?)`"", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $ret = @()
    foreach($m in $mx) {
        $r = @{}
        $r.Add("Name", $m.Groups[1].Value)
        $r.Add("URI", "http://$RouterName{0}" -f $m.Groups[2].Value)
        $ret += ([PSCustomObject]$r)
    }

    if ($GraphName) {
        $obj = $ret | ? Name -like $GraphName | select -first 1
		
		$ps = [PowerShell]::Create()
		$ps.Runspace = [RunSpaceFactory]::CreateRunspace()
		$ps.Runspace.ApartmentState = 'STA'
		$ps.Runspace.Open()
		$ps.Runspace.SessionStateProxy.setVariable("obj", $obj)
		$ps.AddScript({
            Add-Type –assemblyName PresentationFramework, PresentationCore, WindowsBase

            $wb = new-object System.Windows.Controls.WebBrowser
            $wb.Navigate([Uri]$obj.URI)

            $window = New-Object Windows.Window
            $window.Title = $obj.Name
            $window.Content = $wb
            $window.Width = 600
            $window.Height = 300
            $window.ShowDialog()
		}).BeginInvoke() | out-null
    } else {
        return $ret
    }
}

function Get-RegexRouterValue($Content, $Pattern) {
    $m = [regex]::Match($Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m.Success) {
        return HtmlDecode($m.Groups[1].Value)
    } else { Throw "Item not found for pattern $Pattern" }
}

function Split-RouterValue($csv, $Headers) {
    if (-Not $csv.Contains(',')) { return <# Throw "The data was not in the expected (CSV) format: $csv" #> }

    $output = @()
    $arr = ([string]$csv).ToCharArray()
    $current = ""
    $Inside = $false
    for ($i = 0; $i -lt $arr.Length; $i++) {
        $ch = $arr[$i]
        if ($ch -eq "'") {
            $Inside = -Not $Inside
            if (-Not $Inside) {
                $output += $current
                $current = ""
            }
        } elseif ($ch -eq ",") {
            # remove
        } else {
            $current += $ch
        }
    }
    return MapTo-Array $output $Headers
}

function MapTo-Array($array, $map) {
    $ret = @()
    for($i = 0; $i -lt $array.Length; $i += $map.Length) {
        $tab = @{}
        for ($m = 0; $m -lt $map.Length; $m++) {
            # use !ValueName to define a value, but omit it from the result collection.
            if (($map[$m])[0] -ne "!") {
                $tab.Add($map[$m].Replace("'","").Trim(), $array[$i + $m].Trim())
            }
        }
        $ret += [PSCustomObject]$tab
    }
    return $ret
}

function Get-MacAddressOui {
<#
	.SYNOPSIS
		Gets a MAC address OUI (Organizationally Unique Identifier).

	.DESCRIPTION
		The Get-MacAddressOui function retrieves the MAC address OUI reference list maintained by the IEEE standards website and
		returns the name of the company to which the MAC address OUI is assigned.

	.PARAMETER MacAddress
		Specifies the MAC address for which the OUI should be retrieved.

	.EXAMPLE
		Get-MacAddressOui 00:02:B3:FF:FF:FF
		Returns the MAC address OUI and the company assigned that idenifier.

	.INPUTS
		System.String

	.OUTPUTS
		PSObject

	.NOTES
		Name: Get-MacAddressOui
		Author: Rich Kusak (rkusak@hotmail.com)
		Created: 2011-09-01
		LastEdit: 2011-09-06 19:09
		Version: 1.0.3.0

	.LINK
		http://standards.ieee.org/develop/regauth/oui/oui.txt

	.LINK
		about_regular_expressions

#>

	[CmdletBinding()]
	param (
		[Parameter(Position=0, Mandatory=$true, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
		[ValidateScript({
			# Builds regex patterns for the 4 MAC address hex formats
			$patterns = @(':', '-', $null) | ForEach {"^([0-9a-f]{2}$_){5}([0-9a-f]{2})$"}
			$patterns += '^([0-9a-f]{4}\.){2}([0-9a-f]{4})$'

			if ($_ -match ($patterns -join '|')) {$true} else {
				throw "The argument '$_' does not match a valid MAC address format."
			}
		})]
		[string]$MacAddress
	)
	
	begin {
		$uri = 'http://standards.ieee.org/develop/regauth/oui/oui.txt'
		$webClient = New-Object System.Net.WebClient
		
		try {
			Write-Debug "Performing operation 'DownloadString' on target '$uri'."
			$ouiReference = $webClient.DownloadString($uri)
		} catch {
			throw $_
		}
		
		$properties = 'MacAddress', 'OUI', 'Company'
	} # begin
	
	process {
		$oui = ($MacAddress -replace '\W').Remove(6)
		$regex = "($oui)\s*\(base 16\)\s*(.+)"
		
		New-Object PSObject -Property @{
			'MacAddress' = $MacAddress
			'OUI' = $oui
			'Company' = [regex]::Match($ouiReference, $regex, 'IgnoreCase').Groups[2].Value
		} | Select $properties
	} # process
} # function Get-MacAddressOui