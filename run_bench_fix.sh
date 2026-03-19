#!/bin/bash
set -e

# Compile the benchmark
echo "Compiling benchmark..."
go build -o throughput_vs_latency_bench scripts/bench/throughput_vs_latency_bench.go

# Cleanup old results
rm -f throughput_vs_latency*.json throughput_vs_latency*.png *.pprof

# Run Workload A: 100% SET (Write Heavy)
# Capturing profile here at 30k ops/sec as requested
echo "Running Workload A: 100% SET (with Profiling at 30k)"
./throughput_vs_latency_bench \
    -host localhost \
    -port 7379 \
    -start-rate 10000 \
    -end-rate 50000 \
    -step-rate 5000 \
    -step-duration 5s \
    -ratio 0.0 \
    -cpu-profile cpu_profile_30k.pprof \
    -profile-rate 30000
mv throughput_vs_latency.json throughput_vs_latency_ratio_0.00.json

# Run Workload B: 90% GET (Read Heavy)
echo "Running Workload B: 90% GET"
./throughput_vs_latency_bench \
    -host localhost \
    -port 7379 \
    -start-rate 10000 \
    -end-rate 80000 \
    -step-rate 10000 \
    -step-duration 5s \
    -ratio 0.9
mv throughput_vs_latency.json throughput_vs_latency_ratio_0.90.json

# Run Workload C: 50% GET (Mixed)
echo "Running Workload C: 50% GET"
./throughput_vs_latency_bench \
    -host localhost \
    -port 7379 \
    -start-rate 10000 \
    -end-rate 60000 \
    -step-rate 5000 \
    -step-duration 5s \
    -ratio 0.5
mv throughput_vs_latency.json throughput_vs_latency_ratio_0.50.json

# Generate Flamegraph
if [ -f cpu_profile_30k.pprof ]; then
    echo "Generating Flamegraph..."
    go tool pprof -png cpu_profile_30k.pprof > flamegraph_30k.png
else
    echo "Warning: CPU profile not found"
fi

# Plot Results
echo "Plotting results..."
python3 scripts/bench/plot_latency_throughput.py

echo "Done. Check throughput_vs_latency_combined.png and flamegraph_30k.png"
