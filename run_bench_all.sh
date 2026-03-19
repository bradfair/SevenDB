#!/bin/bash
set -e

echo "Running Baseline (SET)..."
go run scripts/bench/throughput_vs_latency_bench.go -host 127.0.0.1 -port 7379 -step-duration 5s

echo "Running 90:10..."
go run scripts/bench/throughput_vs_latency_bench.go -read-ratio 0.9 -host 127.0.0.1 -port 7379 -step-duration 5s

echo "Running 50:50..."
go run scripts/bench/throughput_vs_latency_bench.go -read-ratio 0.5 -host 127.0.0.1 -port 7379 -step-duration 5s

echo "Running Profile Run (30k ops/sec)..."
# Start bench in background, run single step at 30k for 30s
go run scripts/bench/throughput_vs_latency_bench.go -read-ratio 0.5 -host 127.0.0.1 -port 7379 -step-duration 30s -start-rate 30000 -end-rate 30000 &
BENCH_PID=$!

sleep 10
echo "Capturing CPU profile..."
# Using localhost:9090 for metrics server
curl -o cpu_30k.prof "http://localhost:9090/debug/pprof/profile?seconds=10"

wait $BENCH_PID
echo "Benchmarks and Profiling Done."
