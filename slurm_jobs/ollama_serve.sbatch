#!/bin/bash
# Single-GPU Ollama server. Daily driver for the coding assistant.
# Submit from the repo root: sbatch slurm_jobs/ollama_serve.sbatch
#SBATCH --job-name=ollama_serve
# c3_short and c3 are the SAME six nodes (compute300-305, 1x A40 each); they
# differ only in time limit -- 9 h vs 7 d -- and in how contended they are.
# c3_short is far shallower, so a short-lived server schedules sooner there.
# Switch to c3 if you ever want this to outlive 9 hours.
#SBATCH --partition=c3_short
#SBATCH --time=0-08:00:00
#SBATCH --ntasks=1
# 4, not 8. With weights fully on the GPU the server sits near 0.1% CPU; the one
# heavy phase is the cold model load, which is disk-I/O bound rather than CPU
# bound. An 8-CPU ask left this job queued behind nodes whose A40 was idle but
# which had only 4 free CPUs. Memory stays generous: it is page cache for the
# mmap'd weights, which is what makes a reload fast.
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G
#SBATCH -o slurm_jobs/logs/ollama_serve_out.txt
#SBATCH -e slurm_jobs/logs/ollama_serve_err.txt
#SBATCH --gres=gpu:1

# .bashrc is NOT sourced by batch jobs. Source it explicitly to pick up the
# OLLAMA_* variables and $HOME/bin on PATH. Do this BEFORE `set -e`: .bashrc
# uses `[ -s file ] && source file` patterns that return non-zero when a file
# is absent, which would abort the job during startup with no useful message.
module purge
source ~/.bashrc

# Guard: if OLLAMA_MODELS is unset or its directory is missing, ollama will
# silently re-download ~117 GB of weights into $HOME (a 100 GB share). Fail loudly.
if [ ! -d "$OLLAMA_MODELS" ]; then
    echo "OLLAMA_MODELS is unset or missing: '${OLLAMA_MODELS}'"
    exit 1
fi

# Exit immediately if command fails
set -e

echo "Pinning to GPU ${CUDA_VISIBLE_DEVICES} on $(hostname)"
echo "Endpoint will be ${OLLAMA_HOST} on $(hostname)"
nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv

# Foreground, NOT backgrounded: when the last command exits, Slurm tears down
# the allocation. Running in the foreground makes the job last as long as the server.
ollama serve
