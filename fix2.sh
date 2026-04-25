#!/bin/bash
for script in benchmark/mpfuzz_{mqtt,nanomq,flashmq}/run_mpfuzz.sh; do
    sed -i 's/GCOVR_CSV="${OUTDIR}\/cov_over_time.csv"/GCOVR_CSV="$(realpath -m ${OUTDIR})\/cov_over_time.csv"/' "$script"
done
