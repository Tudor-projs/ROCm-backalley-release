# ============================================================================
#  rocm-backalley automated quality gate v3
#    gate3.ps1 -Tag <label> -Bin <build bin dir> [-Reference <tag>]
#
#  v3 adds STEP 5: a batched throughput SWEEP with repetitions.
#  v1 shipped a decode-path regression (#28102); v2 shipped a -62% prefill
#  regression at exactly npl=4. Both hid in a shape the gate never measured,
#  or measured once without repeats. This gate sweeps every batch size in the
#  range where dispatch thresholds live, repeats each, and fails per cell.
#  Fails closed.
# ============================================================================
param(
  [Parameter(Mandatory=$true)][string]$Tag,
  [Parameter(Mandatory=$true)][string]$Bin,
  [string]$Reference = ""
)
$ErrorActionPreference = "Continue"
$ROOT   = "C:\Projects\rocm-backalley"
$res    = "$ROOT\results"
$log    = "$res\gate3_$Tag.log"
$model  = "C:\Projects\moe-4gb-search\models\Qwen3-4B-Q4_K_M.gguf"
$corpus = "C:\Projects\moe-4gb-search\wiki.test.raw"
$logits = "$res\logits_reference.bin"
$REPS   = 3
$NPL    = @(1,2,3,4,5,6,8)      # every batch size where a dispatch threshold can sit
$REG_PCT = -5.0                  # per-cell regression threshold vs reference
$SPREAD_MAX = 12.0               # a cell noisier than this is untrustworthy, not a pass

function L($m){ "$((Get-Date).ToString('HH:mm:ss'))  $m" | Out-File -Append -FilePath $log -Encoding utf8 }
function Save(){ $g | ConvertTo-Json -Depth 6 | Out-File "$res\gate3_$Tag.json" -Encoding utf8 }
function Fail($m){ L ("FAIL: " + $m); $g.verdict="FAIL"; $g.reason=$m; Save; exit 1 }
function Idle(){ while((Get-Process llama-bench,llama-batched-bench,test-backend-ops,llama-perplexity -EA SilentlyContinue|Measure-Object).Count -gt 0){ Start-Sleep 6 } }

"=== GATE3 [$Tag] bin='$Bin' ref='$Reference' $(Get-Date) ===" | Out-File -FilePath $log -Encoding utf8
$g = @{ tag=$Tag; bin=$Bin; reference=$Reference; date=(Get-Date).ToString("s") }

if(-not (Test-Path $Bin)){ Fail "bin dir not found: $Bin" }
foreach($e in "test-backend-ops.exe","llama-perplexity.exe","llama-batched-bench.exe"){
  if(-not (Test-Path "$Bin\$e")){ Fail "missing binary: $e" }
}
$busy=(Get-Process llama-bench,llama-batched-bench,test-backend-ops,llama-perplexity -EA SilentlyContinue|Measure-Object).Count
if($busy -gt 0){ Fail "$busy GPU bench process already running" }
$env:HIP_PATH="C:\Program Files\AMD\ROCm\7.2\"; $env:PATH=$env:HIP_PATH+"bin;"+$env:PATH
$env:HIP_VISIBLE_DEVICES="0"; $env:ROCR_VISIBLE_DEVICES="0"
$env:GGML_CUDA_DQ_MMV="1"; $env:GGML_CUDA_DQ_Q6K="1"

# ---- 1. op correctness -----------------------------------------------------
L "[1/5] op correctness"
$o = & "$Bin\test-backend-ops.exe" 2>&1
$txt = ($o -join "`n") -replace "\x1b\[[0-9;]*m",""
if($txt -notmatch "RX 9070"){ Fail "not running on the RX 9070" }
if($txt -notmatch "tests passed"){ Fail "test-backend-ops produced no result line (did it start?)" }
$passed=$null; if($txt -match "(\d+)/(\d+) tests passed"){ $passed=[int]$Matches[1]; $g.ops_total=[int]$Matches[2] }
if($passed -eq $null){ Fail "could not parse pass count" }
$failing=@(); # newer test-backend-ops prints "[OP] ERR = x > y   CASE(...): FAIL" on one line, so the case name is no
# longer at the start of the line; match it wherever it sits before ": FAIL" (same cases, same verdict logic)
foreach($line in ($txt -split "`n")){ if($line -match "(\S+\(.*\)):\s*FAIL\s*$"){ $failing += $Matches[1] } }
$g.ops_passed=$passed; $g.ops_fail_count=$failing.Count; $g.ops_failing=$failing
# fail closed: a shortfall we cannot attribute to a named op is NOT a pass.
if($passed -lt $g.ops_total -and $failing.Count -eq 0){
  Fail ("unidentified op failure: {0}/{1} passed but no FAIL line parsed" -f $passed,$g.ops_total)
}
$failing | Out-File "$res\gate3_opsfail_$Tag.txt" -Encoding utf8
L ("  $passed/$($g.ops_total) passed, failing: " + $failing.Count)

# ---- 2. perplexity ---------------------------------------------------------
L "[2/5] perplexity"
Idle
$p = & "$Bin\llama-perplexity.exe" -m $model -f $corpus -ngl 99 --chunks 32 -c 512 2>&1
$ppl=$null; foreach($l in $p){ if($l -match "Final estimate: PPL = ([\d.]+)"){ $ppl=[double]$Matches[1] } }
if($ppl -eq $null){ Fail "could not parse perplexity" }
$g.ppl=$ppl; L ("  PPL = " + $ppl)

# ---- 3. KL divergence ------------------------------------------------------
Idle
if($Reference -eq ""){
  L "[3/5] saving reference logits"
  $k = & "$Bin\llama-perplexity.exe" -m $model -f $corpus -ngl 99 --chunks 32 -c 512 --kl-divergence-base $logits 2>&1
  $k | Out-File "$res\gate3_kl_$Tag.txt" -Encoding utf8
  if(-not (Test-Path $logits)){ Fail "reference logits not written" }
  $g.kl_mean=0.0; $g.top1_agree=100.0
  L ("  saved " + [math]::Round((Get-Item $logits).Length/1MB,1) + " MB")
} else {
  L "[3/5] KL divergence vs reference"
  if(-not (Test-Path $logits)){ Fail "no reference logits on disk" }
  $k = & "$Bin\llama-perplexity.exe" -m $model -f $corpus -ngl 99 --chunks 32 -c 512 --kl-divergence --kl-divergence-base $logits 2>&1
  $k | Out-File "$res\gate3_kl_$Tag.txt" -Encoding utf8
  $kt = ($k -join "`n")
  if($kt -match "Mean\s+KLD:\s*([\d.eE+-]+)"){ $g.kl_mean=[double]$Matches[1] }
  if($kt -match "Same top p:\s*([\d.]+)"){ $g.top1_agree=[double]$Matches[1] }
  L ("  mean KLD = " + $g.kl_mean + "   same-top = " + $g.top1_agree + "%")
}

# ---- 4. winogrande ---------------------------------------------------------
L "[4/5] winogrande"
$wgFile="C:\Projects\moe-4gb-search\winogrande.csv"
if(Test-Path $wgFile){
  Idle
  $w = & "$Bin\llama-perplexity.exe" -m $model -f $wgFile -ngl 99 --winogrande --winogrande-tasks 150 2>&1
  $acc=$null
  foreach($l in $w){ if($l -match "Final Winogrande score\(\s*\d+\s*tasks\)\s*:\s*([\d.]+)"){ $acc=[double]$Matches[1] } }
  if($acc -eq $null){ Fail "winogrande: could not parse the score line" }
  if($acc -le 0 -or $acc -gt 100){ Fail ("winogrande: implausible score {0} (parsed the task count?)" -f $acc) }
  $g.winogrande=$acc; L ("  winogrande = {0:N2}%" -f $acc)
} else { L "  dataset absent - skipped"; $g.winogrande=$null }

# ---- 5. NEW: batched throughput sweep, repeated ----------------------------
L "[5/5] batched throughput sweep  npl=$($NPL -join ',')  reps=$REPS"
$sweep=@{}
foreach($n in $NPL){
  $pp=@(); $tg=@()
  for($r=1; $r -le $REPS; $r++){
    Idle
    $o = & "$Bin\llama-batched-bench.exe" -m $model -ngl 99 -c 4096 -b 2048 -ub 512 -npp 128 -ntg 64 -npl $n -fa 1 2>&1
    foreach($ln in $o){
      if("$ln" -match '^\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*[\d.]+\s*\|\s*([\d.]+)\s*\|\s*[\d.]+\s*\|\s*([\d.]+)\s*\|'){
        $pp += [double]$Matches[1]; $tg += [double]$Matches[2]
      }
    }
  }
  if($pp.Count -eq 0){ Fail "batched-bench produced no parseable row at npl=$n" }
  $ppAvg=($pp|Measure-Object -Average).Average
  $ppSpread=((($pp|Measure-Object -Maximum).Maximum-($pp|Measure-Object -Minimum).Minimum)/$ppAvg*100)
  $tgAvg=($tg|Measure-Object -Average).Average
  $tgSpread=((($tg|Measure-Object -Maximum).Maximum-($tg|Measure-Object -Minimum).Minimum)/$tgAvg*100)
  $sweep["npl$n"]=@{pp=$ppAvg; pp_spread=$ppSpread; tg=$tgAvg; tg_spread=$tgSpread; pp_reps=$pp; tg_reps=$tg}
  L ("  npl={0,-2}  S_PP {1,9:N2} (sp {2,4:N1}%)   S_TG {3,8:N2} (sp {4,4:N1}%)" -f $n,$ppAvg,$ppSpread,$tgAvg,$tgSpread)
}
$g.sweep=$sweep

# ---- verdict ---------------------------------------------------------------
if($Reference -eq ""){
  $g.verdict="REFERENCE"; Save
  L "=== reference established (no pass/fail) ==="
  exit 0
}
$refPath="$res\gate3_$Reference.json"
if(-not (Test-Path $refPath)){ Fail "reference json missing: $refPath" }
$ref = Get-Content $refPath -Raw | ConvertFrom-Json

$problems=@()
$pplDelta=[math]::Abs($g.ppl - $ref.ppl)/$ref.ppl*100
$g.ppl_delta_pct=[math]::Round($pplDelta,4)
if($pplDelta -gt 0.5){ $problems += ("perplexity moved {0:N3}% (>0.5%)" -f $pplDelta) }
if($g.kl_mean -ne $null -and $g.kl_mean -gt 0.01){ $problems += ("mean KLD {0} (>0.01)" -f $g.kl_mean) }
if($g.winogrande -ne $null -and $ref.winogrande -ne $null){
  $wdelta = $g.winogrande - $ref.winogrande
  $g.winogrande_delta = [math]::Round($wdelta,3)
  if([math]::Abs($wdelta) -gt 2.0){ $problems += ("winogrande moved {0:N2} points (>2.0)" -f $wdelta) }
}
$newFails = @($g.ops_failing | Where-Object { $ref.ops_failing -notcontains $_ })
if($newFails.Count -gt 0){ $problems += ("new failing ops: " + ($newFails -join ", ")) }

L ""
L "  sweep vs reference:"
L ("  {0,-8} {1,12} {2,12} {3,9}   {4,10} {5,10} {6,9}" -f "npl","ref S_PP","S_PP","d%","ref S_TG","S_TG","d%")
foreach($n in $NPL){
  $k="npl$n"
  $rp=$ref.sweep.$k; $cp=$sweep[$k]
  if($rp -eq $null){ continue }
  $dpp=($cp.pp-$rp.pp)/$rp.pp*100
  $dtg=($cp.tg-$rp.tg)/$rp.tg*100
  $mark=""
  if($dpp -lt $REG_PCT){ $mark+=" <-- PP REGRESSION"; $problems += ("S_PP npl=$n {0:N1}%" -f $dpp) }
  if($dtg -lt $REG_PCT){ $mark+=" <-- TG REGRESSION"; $problems += ("S_TG npl=$n {0:N1}%" -f $dtg) }
  if($cp.pp_spread -gt $SPREAD_MAX){ $problems += ("S_PP npl=$n too noisy to certify ({0:N1}%)" -f $cp.pp_spread) }
  L ("  {0,-8} {1,12:N2} {2,12:N2} {3,8:N1}%   {4,10:N2} {5,10:N2} {6,8:N1}%{7}" -f $n,$rp.pp,$cp.pp,$dpp,$rp.tg,$cp.tg,$dtg,$mark)
}
L ""
if($problems.Count -gt 0){
  foreach($p in $problems){ L ("  ! " + $p) }
  Fail (("{0} problem(s): " -f $problems.Count) + ($problems -join " | "))
}
$g.verdict="PASS"; Save
L "=== PASS ==="
exit 0
