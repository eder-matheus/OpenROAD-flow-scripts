#!/bin/bash -x

techs=("asap7" "gf180" "nangate45" "sky130hd" "sky130hs")

asap7Designs=("aes" "ethmac" "ibex" "jpeg" "sha3")
gf180Designs=("aes")
nangate45Designs=("aes" "black_parrot" "bp_be_top" "bp_fe_top" "bp_multi_top" "ibex" "jpeg" "swerv_wrapper" "tinyRocket")
sky130hdDesigns=("aes" "chameleon" "coyote_tc" "ibex" "jpeg" "microwatt" "riscv32i")
sky130hsDesigns=("aes" "coyote_tc" "ibex" "jpeg" "riscv32i")

for adjust in 0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8
do
  mkdir "adjust_${adjust}"
  export RESOURCES_ADJUSTMENT="${adjust}"
  for tech in "${techs[@]}"
  do
    designs=("${asap7Designs[@]}")

    case $tech in
      "gf180")
        designs=("${gf180Designs[@]}")
        ;;
      "nangate45")
        designs=("${nangate45Designs[@]}")
        ;;
      "sky130hd")
        designs=("${sky130hdDesigns[@]}")
        ;;
      "sky130hs")
        designs=("${sky130hsDesigns[@]}")
        ;;
    esac

    for design in "${designs[@]}"
    do
      nice test/test_helper.sh $design $tech
      make DESIGN_CONFIG=./designs/${tech}/${design}/config.mk final_report_issue
    done
  done
  mv *.tar.gz "adjust_${adjust}"
  make nuke
  rm run-me-* vars-*
done