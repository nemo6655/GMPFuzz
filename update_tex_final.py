import re

tex_file = "/home/pzst/mqtt_fuzz/GMPFuzz/test.tex"
with open(tex_file, "r") as f:
    text = f.read()

old_nanomq = r"        NanoMQ    & 425  & 431  & -6 (-1.4\%)      & 422 & +3 (+0.7\%)      & 421 & +4 (+1.0\%) \\"
new_nanomq = r"        NanoMQ    & 3407 & 3350 & +57 (+1.7\%)    & 3121 & +286 (+9.2\%)  & 3099 & +308 (+9.9\%) \\"

old_avg = r"        \textbf{AVERAGE} & \textbf{2026} & 1744 & +282 (+16.2\%) & 952  & +1074 (+112.8\%) & 1064 & +962 (+90.4\%) \\"
new_avg = r"        \textbf{AVERAGE} & \textbf{2481} & 2088 & +393 (+18.8\%) & 1479 & +1002 (+67.7\%) & 1557 & +924 (+59.3\%) \\"

# Also updating the analysis text
old_nano_analysis = r"For \textbf{NanoMQ}, all fuzzers achieve highly comparable coverage (421-431 branches). GMPFuzz covers 425 branches, slightly trailing AFLNet (-1.4\%) but marginally beating MPFuzz and Peach. This indicates that NanoMQ's reachable attack surface under the defined test harnessed configuration is relatively small or hits a shared protocol-state bottleneck early on, where both mutation-based and generation-based fuzzers quickly saturate shallow code pathways."

new_nano_analysis = r"For \textbf{NanoMQ}, the overall coverage numbers are intrinsically higher thanks to a resolved instrumentation scope. GMPFuzz reaches 3407 branches, successfully outperforming AFLNet (3350 branches) by 1.7\%. Generation-based fuzzers like MPFuzz and Peach achieve roughly 3100 branches, meaning GMPFuzz leads them by nearly 10\%. This demonstrates GMPFuzz's capacity to maintain a steady advantage in structurally complex protocol fields even as the target's internal pathways deepen."

text = text.replace(old_nanomq, new_nanomq)
text = text.replace(old_avg, new_avg)
text = text.replace(old_nano_analysis, new_nano_analysis)

# And the overall average paragraph mentions -> 2481, +18.8%, +67.7%, +59.3%
text = re.sub(
    r"GMPFuzz.*?achieves the highest average branch coverage \(2026 branches\).*?AFLNet \(\+16\.2\%\) and generation-based baselines like MPFuzz \(\+112\.8\%\) and Peach \(\+90\.4\%\)\.",
    r"GMPFuzz achieves the highest average branch coverage (2481 branches), significantly outperforming all baseline fuzzers across the 24-hour timeframe. It demonstrates a substantial overall improvement over AFLNet (+18.8%) and generation-based baselines like MPFuzz (+67.7%) and Peach (+59.3%).",
    text,
    flags=re.DOTALL
)

with open(tex_file, "w") as f:
    f.write(text)

