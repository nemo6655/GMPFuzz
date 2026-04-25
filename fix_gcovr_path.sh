#!/bin/bash
for script in benchmark/mpfuzz_mqtt/run_mpfuzz.sh benchmark/mpfuzz_nanomq/run_mpfuzz.sh benchmark/mpfuzz_flashmq/run_mpfuzz.sh; do
    sed -i 's/GCOVR_CSV=.*cov_over_time.csv"/GCOVR_CSV="$(cd "${OUTDIR}" \&\& pwd)\/cov_over_time.csv"/' "$script"
    echo "Fixed $script"
done
