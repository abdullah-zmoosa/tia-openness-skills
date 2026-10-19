param(
    [Parameter(Mandatory=$true)][string]$BlocksDir
)
$ErrorActionPreference = 'Stop'

function Render-Node {
    param([System.Xml.XmlNode]$node, [System.Text.StringBuilder]$sb)
    if ($node -is [System.Xml.XmlText]) { return }
    $ln = $node.LocalName
    switch ($ln) {
        'Token'         { [void]$sb.Append($node.GetAttribute("Text")) }
        'Blank'         { [void]$sb.Append(' ' * [int]$node.GetAttribute("Num")) }
        'NewLine'       {
                            $n = [int]$node.GetAttribute("Num")
                            for ($i = 0; $i -lt $n; $i++) { [void]$sb.AppendLine() }
                        }
        'Text'          { [void]$sb.Append($node.InnerText) }
        'LineComment'   {
                            [void]$sb.Append('//')
                            $txtChild = $node.SelectSingleNode("*[local-name()='Text']")
                            if ($txtChild) { [void]$sb.Append($txtChild.InnerText) }
                        }
        'Component'     { [void]$sb.Append($node.GetAttribute("Name")) }
        'Constant'      {
                            $cname = $node.GetAttribute("Name")
                            if ($cname) {
                                [void]$sb.Append($cname)
                            } else {
                                foreach ($child in $node.ChildNodes) { Render-Node $child $sb }
                            }
                        }
        'ConstantValue' { [void]$sb.Append($node.InnerText) }
        'Instruction'   {
                            [void]$sb.Append($node.GetAttribute("Name"))
                            foreach ($child in $node.ChildNodes) { Render-Node $child $sb }
                        }
        'Parameter'     {
                            [void]$sb.Append($node.GetAttribute("Name"))
                            foreach ($child in $node.ChildNodes) { Render-Node $child $sb }
                        }
        default         {
                            foreach ($child in $node.ChildNodes) { Render-Node $child $sb }
                        }
    }
}

$xmlFiles = Get-ChildItem $BlocksDir -Filter *.xml
$count = 0
foreach ($file in $xmlFiles) {
    [xml]$x = [System.IO.File]::ReadAllText($file.FullName)
    $stNodes = $x.SelectNodes("//*[local-name()='StructuredText']")
    if ($stNodes.Count -eq 0) { continue }
    $sb = New-Object System.Text.StringBuilder
    foreach ($stNode in $stNodes) {
        if ($sb.Length -gt 0) { [void]$sb.AppendLine() }
        foreach ($child in $stNode.ChildNodes) { Render-Node $child $sb }
    }
    if ($sb.Length -gt 0) {
        $outPath = [IO.Path]::ChangeExtension($file.FullName, '.scl')
        [System.IO.File]::WriteAllText($outPath, $sb.ToString(), [System.Text.Encoding]::UTF8)
        $count++
    }
}
Write-Host ("SCL extraction done: " + $count + " files written")