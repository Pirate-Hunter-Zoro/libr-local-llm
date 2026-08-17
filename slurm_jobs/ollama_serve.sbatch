#!/bin/bash
# Single-GPU Ollama server. Daily driver for the coding assistant.
# Submit from the repo root: sbatch slurm_jobs/ollama_serve.sbatch
#SBATCH --job-name=ollama_serve
#SBATCH --partition=c3
#SBATCH --time=0-08:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
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
