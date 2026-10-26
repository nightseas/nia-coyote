#!/bin/bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

NIA_GATE_FAILS=0

nia_gate_pass() { echo "NIA_GATE $1 PASS  $2"; }
nia_gate_fail() { echo "NIA_GATE $1 FAIL  $2"; NIA_GATE_FAILS=$((NIA_GATE_FAILS + 1)); }

nia_impl_constraint_dirs() {
  local src="$1" fdev="$2" d
  for d in "static/impl" "shell/impl" "dynamic/impl" "dcmac" "fplan"; do
    [ -d "$src/hw/constraints/$fdev/$d" ] && echo "$src/hw/constraints/$fdev/$d"
  done
}

nia_all_constraint_files() {
  local src="$1" fdev="$2"
  [ -d "$src/hw/constraints/$fdev" ] || return 0
  find "$src/hw/constraints/$fdev" -name '*.xdc' | sort
}

nia_gate_a1_xdc_parses() {
  local src="$1" fdev="$2" part="$3" out="$4"
  local files; files=$(nia_all_constraint_files "$src" "$fdev")
  if [ -z "$files" ]; then
    nia_gate_pass A1_xdc_parses "no constraint files for $fdev (nothing to check)"
    return 0
  fi
  mkdir -p "$out/a1"
  local rc=0
  local bad_kw='if|for|while|switch|proc|catch|eval'
  local n_bad=0 f
  for f in $files; do
    [ -f "$f" ] || continue
    local hits
    hits=$(sed 's/#.*//' "$f" | grep -nE "^[[:space:]]*($bad_kw)[[:space:]{(]" || true)
    if [ -n "$hits" ]; then
      nia_gate_fail A1_xdc_parses \
        "$f uses Tcl control flow, which Vivado's XDC dialect rejects with [Designutils 20-1307]. The guarded statements are SILENTLY NOT APPLIED and the build fails much later somewhere else (attempt 1: two set_property LOCs skipped, then [DRC MGTIO-17] GT quad not placed, ~34 min in). Move the guard out of the XDC and into the flow script that adds the file."
      echo "$hits" | sed "s|^|      $f:|"
      n_bad=$((n_bad + 1))
    fi
  done
  [ "$n_bad" -gt 0 ] && rc=1

  local log="$out/a1/preflight_xdc.log"
  # shellcheck disable=SC2086
  ( cd "$out/a1" && env TERM=xterm vivado -mode batch -notrace \
      -source "$src/scripts/nia/coyote_tu03_preflight.tcl" \
      -tclargs "$part" $files ) > "$log" 2>&1
  local n_fail; n_fail=$(grep -c '^NIA_PREFLIGHT_XDC FAIL' "$log")
  local n_pass; n_pass=$(grep -c '^NIA_PREFLIGHT_XDC PASS' "$log")
  if [ ! -s "$log" ] || ! grep -q '^NIA_PREFLIGHT_DONE' "$log"; then
    nia_gate_fail A1_xdc_parses "the pre-flight Vivado run produced no NIA_PREFLIGHT_DONE marker (log=$log)"
    return 1
  fi
  if [ "$n_fail" -gt 0 ]; then
    nia_gate_fail A1_xdc_parses "$n_fail constraint file(s) rejected by read_xdc:"
    grep '^NIA_PREFLIGHT_XDC FAIL' "$log" | sed 's/^/    /'
    echo "    log=$log"
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    nia_gate_pass A1_xdc_parses "$n_pass file(s): 0 control-flow constructs (lint) and 0 read_xdc errors (log=$log)"
  fi
  return $rc
}

nia_gate_a2_impl_fileset() {
  local src="$1" fdev="$2" phy="$3"
  local impl_dirs; impl_dirs=$(nia_impl_constraint_dirs "$src" "$fdev")
  local bad=0 f d port

  local impl_ports=""
  for d in $impl_dirs; do
    impl_ports="$impl_ports $(grep -rhE '^[[:space:]]*create_clock' "$d" 2>/dev/null \
      | sed -nE 's/.*get_ports[[:space:]]+\{?([A-Za-z0-9_]+)\}?.*/\1/p')"
  done

  local synth_srcs=""
  for d in "static/synth" "shell/synth"; do
    [ -d "$src/hw/constraints/$fdev/$d" ] && \
      synth_srcs="$synth_srcs $(find "$src/hw/constraints/$fdev/$d" -name '*.xdc')"
  done

  for f in $synth_srcs; do
    if grep -qE '^[[:space:]]*set_property[[:space:]]+LOC' "$f"; then
      nia_gate_fail A2_impl_fileset \
        "$f is synthesis-only (its fileset is marked used_in_implementation false at cr_shell.tcl.in:172 / cr_static.tcl.in:101) but contains a 'set_property LOC'. A placement constraint that implementation never reads does nothing."
      bad=1
    fi
    for port in $(sed -nE 's/^[[:space:]]*create_clock.*get_ports[[:space:]]+\{?([A-Za-z0-9_]+)\}?.*/\1/p' "$f"); do
      if ! echo " $impl_ports " | grep -q " $port "; then
        nia_gate_fail A2_impl_fileset \
          "port '$port' is clocked in the SYNTHESIS-ONLY source $f but by NO implementation-reachable constraint file ($(echo $impl_dirs | tr '\n' ' ')). Everything downstream of it will be routed untimed and report_timing_summary will still say 'All user specified timing constraints are met' - S18 attempt 4, 34290 unclocked register pins at WNS +0.110."
        bad=1
      fi
    done
  done

  if [ "$phy" = "dcmac" ]; then
    local found=0
    for d in $impl_dirs; do
      if grep -rqE '^[[:space:]]*create_clock.*(gt0_refclk_p|gt_ref_clk0_p)' "$d" 2>/dev/null; then found=1; fi
    done
    if [ "$found" -eq 0 ]; then
      nia_gate_fail A2_impl_fileset \
        "DCMAC_PHY=dcmac but NO implementation-reachable constraint file creates the GT reference clock (create_clock on gt0_refclk_p). Without it the whole DCMAC + GT + clock-wizard tree is unconstrained and check_timing will report tens of thousands of unclocked pins while report_timing_summary claims a pass (S18 attempt 4)."
      bad=1
    fi
  fi

  [ "$bad" -eq 0 ] && nia_gate_pass A2_impl_fileset \
    "every port clocked in a synthesis-only source is also clocked by an impl-reachable file, and no synthesis-only file places a cell$([ "$phy" = dcmac ] && echo '; the GT refclk create_clock is present at impl')"
  return $bad
}

nia_gate_a4_stale_link_dcp() {
  local src="$1" fdev="$2" bdir="$3"
  local dcp="$bdir/checkpoints/shell_linked.dcp"
  local stampdir="$bdir/checkpoints"
  local stamp="$stampdir/.nia_xdc_hash"
  local cur
  cur=$( { nia_all_constraint_files "$src" "$fdev" | xargs -r md5sum;
           md5sum "$src/scripts/impl/link.tcl.in" "$src/scripts/dyn/flow_dyn_versal.tcl.in" 2>/dev/null; } \
         | awk '{print $1}' | sort | md5sum | cut -d' ' -f1 )
  if [ ! -f "$dcp" ]; then
    mkdir -p "$stampdir" 2>/dev/null
    echo "$cur" > "$stamp" 2>/dev/null
    nia_gate_pass A4_stale_link_dcp "no shell_linked.dcp yet; recorded constraint hash $cur"
    return 0
  fi
  local old=""
  [ -f "$stamp" ] && old=$(cat "$stamp")
  if [ "$old" = "$cur" ]; then
    nia_gate_pass A4_stale_link_dcp "shell_linked.dcp kept: constraint hash unchanged ($cur)"
    return 0
  fi
  rm -f "$dcp"
  echo "$cur" > "$stamp"
  nia_gate_pass A4_stale_link_dcp \
    "DELETED $dcp because a constraint input changed (was ${old:-<none>}, now $cur). Without this, 'make link' returns rc=0 in 0 s off the stale checkpoint and the edit is never read (S18 attempt 2)."
  return 0
}

nia_gate_a5_timing_honest() {
  local ct="$1" ck="$2" phy="$3" rc=0
  if [ ! -f "$ct" ]; then
    nia_gate_fail A5_timing_honest "no check_timing evidence at $ct - a timing result with no check_timing is not a result"
    return 1
  fi
  local line n
  line=$(grep -m1 'register/latch pins with no clock' "$ct")
  if [ -z "$line" ]; then
    nia_gate_fail A5_timing_honest "$ct contains no 'register/latch pins with no clock' line at all, so 0 cannot be proven"
    rc=1
  else
    n=$(echo "$line" | sed -E 's/.*There are ([0-9]+) register\/latch pins with no clock.*/\1/')
    if [ "$n" != "0" ]; then
      nia_gate_fail A5_timing_honest "check_timing reports $n register/latch pins WITH NO CLOCK: $(echo "$line" | sed 's/^ *//'). Any WNS from this run covers only the clocked part of the design (S18 attempt 4 reported WNS +0.110 with 34290 such pins)."
      rc=1
    else
      nia_gate_pass A5_timing_honest "check_timing: 0 register/latch pins with no clock"
    fi
  fi
  if [ "$phy" = "dcmac" ]; then
    local ev="$ck"; [ -f "$ev" ] || ev="$ct"
    local miss=""
    grep -qE 'gt_ref_clk0_p' "$ev" || miss="$miss gt_ref_clk0_p(156.25MHz)"
    grep -qE '78[0-9]\.[0-9]+|1\.27[0-9]' "$ev" || miss="$miss dcmac_core~782MHz"
    grep -qE '39[01]\.[0-9]+|2\.55[0-9]' "$ev" || miss="$miss dcmac_seg~391MHz"
    if [ -n "$miss" ]; then
      nia_gate_fail A5_timing_honest "the DCMAC clock family is MISSING from $ev:$miss. The GT/DCMAC tree is therefore untimed even if the summary says every constraint is met."
      rc=1
    else
      nia_gate_pass A5_timing_honest "DCMAC clock family present in $ev (refclk + ~782 MHz core + ~391 MHz segmented)"
    fi
  fi
  return $rc
}

nia_gate_a6_crit_codes() {
  local ref="$2"; local logs=("$1"); shift 2
  while [ $# -gt 0 ]; do logs+=("$1"); shift; done
  if [ ! -f "$ref" ]; then
    nia_gate_fail A6_crit_codes "no reference set at $ref"
    return 1
  fi
  local seen new=0
  seen=$(grep -h '^CRITICAL WARNING' "${logs[@]}" 2>/dev/null \
         | grep -oE '\[[A-Za-z]+ [0-9]+-[0-9]+\]' | tr -d '[]' | sort -u)
  local allow; allow=$(grep -vE '^[[:space:]]*(#|$)' "$ref" | sed 's/#.*//' | sed 's/[[:space:]]*$//' | sort -u)
  local c
  for c in $(echo "$seen" | tr ' ' '_'); do :; done
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if ! echo "$allow" | grep -qxF "$c"; then
      local cnt; cnt=$(grep -h '^CRITICAL WARNING' "${logs[@]}" 2>/dev/null | grep -cF "[$c]")
      nia_gate_fail A6_crit_codes "NEW critical-warning group [$c] x$cnt is not in $ref. A new group is a new mechanism: classify it (or label it 'unknown') and add it to the reference with its log citation before quoting this build as clean. First instance:"
      grep -h -m1 -F "[$c]" "${logs[@]}" 2>/dev/null | cut -c1-300 | sed 's/^/      /'
      new=$((new + 1))
    fi
  done <<< "$seen"
  if [ "$new" -eq 0 ]; then
    nia_gate_pass A6_crit_codes "$(echo "$seen" | grep -c .) code(s) seen, all present in the reference: $(echo "$seen" | tr '\n' ' ')"
    return 0
  fi
  return 1
}

nia_crit_shapes() {
  grep -h '^CRITICAL WARNING' "$@" 2>/dev/null \
  | sed -E 's/^CRITICAL WARNING: \[([^]]*)\][[:space:]]*/\1|/' \
  | awk -F'|' 'NF>1 { code=$1; $1=""; sub(/^\|/,""); msg=substr($0,2);
                      print code "\x01" msg }' \
  | while IFS=$'\x01' read -r code msg; do
      m=$(printf '%s' "$msg" \
          | sed -E 's@/[^ ]*/@<PATH>/@g' \
          | sed -E 's/\[[0-9]+(:[0-9]+)?\]/[*]/g' \
          | sed -E 's/:[0-9]+\b/:N/g' \
          | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//' \
          | cut -c1-160)
      printf '%s|%s\n' "$code" "$m"
    done | sort -u
}

nia_gate_a6b_crit_objects() {
  local ref="$2"; local logs=("$1"); shift 2
  while [ $# -gt 0 ]; do logs+=("$1"); shift; done
  if [ ! -f "$ref" ]; then
    nia_gate_fail A6b_crit_objects "no object reference at $ref (regenerate with: $0 regen-crit-objects <log> > $ref)"
    return 1
  fi
  local seen allow new=0 nseen
  seen=$(nia_crit_shapes "${logs[@]}")
  allow=$(grep -vE '^[[:space:]]*(#|$)' "$ref")
  nseen=$(printf '%s\n' "$seen" | grep -c . || true)
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if ! printf '%s\n' "$allow" | grep -qxF "$p"; then
      local code="${p%%|*}"
      nia_gate_fail A6b_crit_objects "NEW critical-warning OBJECT under an EXISTING code [$code]. A6 would not have caught this: the code is in the reference set, so only the object is new. Classify it and add the shape to $ref with its log citation before quoting this build as clean. Shape:"
      printf '      %s\n' "$p"
      grep -h -m1 -F "[$code]" "${logs[@]}" 2>/dev/null | cut -c1-300 | sed 's/^/      first instance: /'
      new=$((new + 1))
    fi
  done <<< "$seen"
  local gone=0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    printf '%s\n' "$seen" | grep -qxF "$p" || { gone=$((gone + 1)); }
  done <<< "$allow"
  if [ "$new" -eq 0 ]; then
    nia_gate_pass A6b_crit_objects "$nseen distinct (code,object) shape(s) from $(grep -hc '^CRITICAL WARNING' "${logs[@]}" 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo '?') warning(s), all present in the reference; $gone reference shape(s) not seen in this build (informational)"
    return 0
  fi
  return 1
}

nia_gate_a7_no_pdi() {
  local bdir="$1"
  local n; n=$(find "$bdir" -name '*.pdi' 2>/dev/null | wc -l)
  echo "PDI-CHECK: $n pdi files"
  if [ "$n" -ne 0 ]; then
    nia_gate_fail A7_no_pdi "$n .pdi file(s) exist under $bdir. on a build host whose DCMAC licence is Design_Linking, write_device_image is blocked, so any PDI here is either not a DCMAC image or not trustworthy. Coyote TU03 claims no PDI (DEV_PLAN §A.8)."
    find "$bdir" -name '*.pdi' | sed 's/^/      /'
    return 1
  fi
  nia_gate_pass A7_no_pdi "0 .pdi files under $bdir"
  return 0
}

nia_gate_a7c_pdi_policy() {
  local bdir="$1" blog="${2:-}" expect="${3:-0}"
  local n; n=$(find "$bdir" -name '*.pdi' 2>/dev/null | wc -l)
  echo "PDI-CHECK: $n pdi files (policy=A7c expect_pdi=$expect)"
  find "$bdir" -name '*.pdi' -exec ls -l {} \; 2>/dev/null | sed 's/^/      /'
  find "$bdir" -name '*.pdi' -exec md5sum {} \; 2>/dev/null | sed 's/^/      /'

  local refused=0 bitgen_ok=0
  if [ -n "$blog" ] && [ -f "$blog" ]; then
    grep -qE 'greater than a Design Linking license|Common 17-69|<encrypted cellview>' "$blog" && refused=1
    grep -qE 'write_device_image completed successfully|NIA_STAGE_END bitgen rc=0' "$blog" && bitgen_ok=1
    echo "PDI-CHECK: licence_refusal_in_log=$refused  bitgen_succeeded=$bitgen_ok  ($blog)"
  else
    echo "PDI-CHECK: no build log supplied — falling back to the count only"
  fi

  if [ "$n" -gt 0 ]; then
    if [ "$refused" = 1 ]; then
      nia_gate_fail A7c_pdi_policy "a .pdi exists AND the log carries a DCMAC licence refusal. The PDI cannot correspond to this netlist — it is stale, or from another configuration. Delete it and rebuild; per DEV_PLAN §A.8 the licence is baked into the IP output products, so the IP must be regenerated on the licensed box."
      return 1
    fi
    if [ -n "$blog" ] && [ -f "$blog" ] && [ "$bitgen_ok" = 0 ]; then
      nia_gate_fail A7c_pdi_policy "a .pdi exists but this build shows no successful bitgen. Nothing in this run wrote it ⇒ it is stale from a previous build. Remove it so the result is attributable."
      return 1
    fi
    nia_gate_pass A7c_pdi_policy "$n .pdi file(s) written by a bitgen that succeeded with no licence refusal ⇒ a real, programmable image"
    return 0
  fi

  if [ "$refused" = 1 ]; then
    nia_gate_pass A7c_pdi_policy "0 .pdi and the log shows the DCMAC licence being refused ⇒ correctly blocked (the routed checkpoint is the artifact)"
    return 0
  fi
  if [ "$expect" = 1 ]; then
    nia_gate_fail A7c_pdi_policy "a .pdi was expected and none exists, with no licence refusal in the log either ⇒ bitgen was skipped or silently produced nothing. Check the stage chain includes 'bitgen'."
    return 1
  fi
  nia_gate_pass A7c_pdi_policy "0 .pdi files under $bdir, and none was expected"
  return 0
}

nia_gate_a7b_pdi_present() {
  local bdir="$1"
  local n; n=$(find "$bdir" -name '*.pdi' 2>/dev/null | wc -l)
  echo "PDI-CHECK: $n pdi files"
  find "$bdir" -name '*.pdi' -exec ls -l {} \; 2>/dev/null | sed 's/^/      /'
  find "$bdir" -name '*.pdi' -exec md5sum {} \; 2>/dev/null | sed 's/^/      /'
  if [ "$n" -eq 0 ]; then
    nia_gate_fail A7b_pdi_present "NIA_LICENSED_DCMAC=1 but no .pdi was produced under $bdir. Either bitgen never ran (check the stage chain) or write_device_image was refused — grep the build log for 'Design Linking', '17-69' and '<encrypted cellview>'. Per DEV_PLAN §A.8 the licence is baked into the IP output products, so a netlist generated on an UNLICENSED box stays un-bitgen-able even here: the fix is to regenerate the IP on this box, i.e. build from source rather than from a carried checkpoint."
    return 1
  fi
  nia_gate_pass A7b_pdi_present "$n .pdi file(s) written under $bdir"
  return 0
}

nia_gate_a3_filters() {
  local vlog="$1"; shift
  local rc=0
  if [ -f "$vlog" ] && grep -q '^NIA_VERIFY_FILTER' "$vlog"; then
    local nf; nf=$(grep -c '^NIA_VERIFY_FILTER FAIL' "$vlog")
    local np; np=$(grep -c '^NIA_VERIFY_FILTER PASS' "$vlog")
    if [ "$nf" -gt 0 ]; then
      nia_gate_fail A3_filters "$nf constraint filter(s) select NO object in the routed design (attempt 3's failure: a filter keyed on the exdes instance name matched nothing and the GT quad was never placed):"
      grep '^NIA_VERIFY_FILTER FAIL' "$vlog" | sed 's/^/      /'
      rc=1
    else
      nia_gate_pass A3_filters "$np constraint filter(s) each select >= 1 object in the routed design"
    fi
  fi
  local hits=0 l
  for l in "$@"; do
    [ -f "$l" ] || continue
    hits=$((hits + $(grep -cE '\[(Vivado 12-180|Common 17-55)\]' "$l")))
  done
  if [ "$hits" -gt 0 ]; then
    nia_gate_fail A3_filters "$hits [Vivado 12-180]/[Common 17-55] empty-object-list message(s) in the build log - a constraint referenced something that does not exist:"
    grep -hE -m3 '\[(Vivado 12-180|Common 17-55)\]' "$@" 2>/dev/null | cut -c1-300 | sed 's/^/      /'
    rc=1
  else
    nia_gate_pass A3_filters "0 [Vivado 12-180] / [Common 17-55] empty-object-list messages in the build log"
  fi
  return $rc
}

nia_gate_a8_clock_groups() {
  local vlog="$1"
  if [ ! -f "$vlog" ] || ! grep -q '^NIA_VERIFY_CLKFAMILY' "$vlog"; then
    nia_gate_fail A8_clock_groups "the verify run produced no NIA_VERIFY_CLKFAMILY facts - report_clock_interaction did not run, so the async grouping is UNVERIFIED (18-5524 says the clock names may have changed inside the IP)"
    return 1
  fi
  local nfam; nfam=$(awk '$1=="NIA_VERIFY_CLKFAMILY" && $3==0' "$vlog" | wc -l)
  if [ "$nfam" -gt 0 ]; then
    nia_gate_fail A8_clock_groups "$nfam clock family(ies) resolved to ZERO clocks - the MMCM cell filter matched nothing, so the grouping cannot have applied:"
    grep '^NIA_VERIFY_CLKFAMILY' "$vlog" | sed 's/^/      /'
    return 1
  fi
  local bad; bad=$(grep -c '^NIA_VERIFY_CLKPAIR TIMED' "$vlog")
  local ok;  ok=$(grep -c '^NIA_VERIFY_CLKPAIR OK' "$vlog")
  if [ "$bad" -gt 0 ]; then
    nia_gate_fail A8_clock_groups "$bad cross-family clock pair(s) are TIMED against each other - the async grouping did not apply to them (this is the -8.4 ns failure mode of S18 attempt 5):"
    grep '^NIA_VERIFY_CLKPAIR TIMED' "$vlog" | sed 's/^/      /'
    return 1
  fi
  if [ "$ok" -eq 0 ]; then
    nia_gate_pass A8_clock_groups "no cross-family clock pair has timing paths at all - nothing to mis-time (check the families above are the expected three)"
    return 0
  fi
  nia_gate_pass A8_clock_groups "$ok cross-family clock pair(s) with timing paths, all cut (asynchronous/exclusive group or false path) after black-box fill-in"
  return 0
}

nia_preflight() {
  local src="$1" fdev="$2" part="$3" out="$4" bdir="$5" phy="$6"
  NIA_GATE_FAILS=0
  echo "NIA_PREFLIGHT_BEGIN src=$src fdev=$fdev part=$part phy=$phy"
  nia_gate_a2_impl_fileset   "$src" "$fdev" "$phy"
  nia_gate_a1_xdc_parses     "$src" "$fdev" "$part" "$out"
  nia_gate_a4_stale_link_dcp "$src" "$fdev" "$bdir"
  if [ "${NIA_LICENSED_DCMAC:-0}" = "1" ]; then
    local n_stale; n_stale=$(find "$bdir" -name '*.pdi' 2>/dev/null | wc -l)
    echo "PDI-CHECK: $n_stale pdi files (pre-flight, NIA_LICENSED_DCMAC=1 -> informational)"
    [ "$n_stale" -ne 0 ] && echo "NIA_GATE A7_no_pdi WARN $n_stale pre-existing .pdi under $bdir; if this build dir is being REUSED, delete them so the post-build A7b assertion cannot pass on a stale file"
  else
    nia_gate_a7_no_pdi       "$bdir"
  fi
  echo "NIA_PREFLIGHT_RESULT rc=$NIA_GATE_FAILS"
  return "$NIA_GATE_FAILS"
}

nia_verify() {
  local src="$1" fdev="$2" part="$3" out="$4" bdir="$5" phy="$6" blog="$7"
  NIA_GATE_FAILS=0
  echo "NIA_VERIFY_BEGIN"
  local dcp="$bdir/checkpoints/shell_routed.dcp"
  [ -f "$dcp" ] || dcp=$(ls -1t "$bdir"/checkpoints/*routed*.dcp 2>/dev/null | head -1)
  local vlog="$out/verify/verify.log"
  mkdir -p "$out/verify"
  if [ -z "$dcp" ] || [ ! -f "$dcp" ]; then
    nia_gate_fail A5_timing_honest "no routed checkpoint under $bdir/checkpoints - there is nothing to verify, so no timing claim may be made"
  else
    # shellcheck disable=SC2046
    ( cd "$out/verify" && env TERM=xterm vivado -mode batch -notrace \
        -source "$src/scripts/nia/coyote_tu03_verify.tcl" \
        -tclargs "$dcp" "$out/verify" $(nia_all_constraint_files "$src" "$fdev" | tr '\n' ' ') ) \
        > "$vlog" 2>&1
    nia_gate_a5_timing_honest "$out/verify/check_timing.rpt" "$out/verify/clocks.rpt" "$phy"
    nia_gate_a3_filters "$vlog" "$blog"
    nia_gate_a8_clock_groups "$vlog"
  fi
  nia_gate_a6_crit_codes "$blog" "$src/scripts/nia/coyote_tu03_crit_reference.txt"
  nia_gate_a6b_crit_objects "$blog" "$src/scripts/nia/coyote_tu03_crit_objects_reference.txt"
  nia_gate_a7_no_pdi "$bdir"
  echo "NIA_VERIFY_RESULT rc=$NIA_GATE_FAILS"
  return "$NIA_GATE_FAILS"
}

if [ "$(basename -- "$0")" = "coyote_tu03_gates.sh" ] && [ "$1" = "regen-crit-objects" ]; then
  shift
  echo "# coyote_tu03_crit_objects_reference.txt - GENERATED by coyote_tu03_gates.sh regen-crit-objects"
  echo "# from: $*"
  echo "# on:   $(date -Is)"
  echo "#"
  echo "# One '<code>|<normalised message shape>' per line. Assertion A6b asserts this SET."
  echo "# A new OBJECT under an already-known code is a new shape and therefore a FAILURE -"
  echo "# which is the hole A6 leaves (doc/design/COYOTE_TU03_DESIGN_SPEC.md S4)."
  nia_crit_shapes "$@"
  exit 0
fi

if [ "$(basename -- "$0")" = "coyote_tu03_gates.sh" ] && [ "$1" = "selftest" ]; then
  shift
  what="$1"; shift
  case "$what" in
    a1) nia_gate_a1_xdc_parses "$@" ;;
    a2) nia_gate_a2_impl_fileset "$@" ;;
    a3) nia_gate_a3_filters "$@" ;;
    a4) nia_gate_a4_stale_link_dcp "$@" ;;
    a5) nia_gate_a5_timing_honest "$@" ;;
    a6) nia_gate_a6_crit_codes "$@" ;;
    a6b) nia_gate_a6b_crit_objects "$@" ;;
    a7) nia_gate_a7_no_pdi "$@" ;;
    a7b) nia_gate_a7b_pdi_present "$@" ;;
    a7c) nia_gate_a7c_pdi_policy "$@" ;;
    a8) nia_gate_a8_clock_groups "$@" ;;
    *)  echo "usage: $0 selftest a1|a2|a3|a4|a5|a6|a6b|a7|a7b|a7c|a8 <args...>"; exit 2 ;;
  esac
  echo "NIA_SELFTEST_RESULT check=$what fails=$NIA_GATE_FAILS"
  exit "$NIA_GATE_FAILS"
fi
