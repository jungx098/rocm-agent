function Expand-PromptTemplate {
    param(
        [Parameter(Mandatory)][string]$TemplateDir,
        [Parameter(Mandatory)][string]$TemplateName,
        [Parameter(Mandatory)][hashtable]$Vars
    )
    $path = Join-Path $TemplateDir $TemplateName
    $t = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    foreach ($k in $Vars.Keys) {
        $t = $t.Replace("{{$k}}", [string]$Vars[$k])
    }
    $t
}
