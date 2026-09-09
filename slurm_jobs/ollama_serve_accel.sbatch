#!/bin/bash
# Four-GPU Ollama server on c3_accel (compute306). Needed only for gpt-oss:120b,
# which is 65.4 GB and cannot fit a single 46 GB A40.
# compute306 is the cluster's ONLY 4-GPU node -- do not camp on it for small models.
# Submit from the repo root: sbatch slurm_jobs/ollama_serve_accel.sbatch
#SBATCH --job-name=ollama_serve_accel
#SBATCH --partition=c3_accel
#SBATCH --time=0-08:00:00
#SBATCH --ntasks=1
# 8, not 16. Measured: this server sits at ~0.1% CPU while holding a 70 GB model
# at 100% GPU. compute306 has 96 CPUs and is shared -- do not reserve what you
# will not use. Memory stays large: page cache for the mmap'd weights.
#SBATCH --cpus-per-task=8
#SBATCH --mem=128G
#SBATCH -o slurm_jobs/logs/ollama_serve_accel_out.txt
#SBATCH -e slurm_jobs/logs/ollama_serve_accel_err.txt
#SBATCH --gres=gpu:4

# See ollama_serve.sbatch for why this is sourced before `set -e`.
module purge
source ~/.bashrc

# Force sharding across every visible GPU rather than trying to fit one card.
# Set AFTER the source so it wins over anything .bashrc might define later.
export OLLAMA_SCHED_SPREAD=1

# Raise the context window for this profile only. ~/.bashrc sets 65536, which
# has to be safe on ONE 46 GB card -- medgemma:27b-it-q8_0 is 29.6 GB of it
# before any KV cache. Here there are four cards and gpt-oss:120b occupies
# 70 GB of 184 GB, so ~114 GB sits idle; there is no reason to serve a 131072
# model at half its window.
#
# The reason this matters for OUTPUT QUALITY, not just capacity: gpt-oss uses
# sliding-window attention (128), and llama.cpp therefore logs "KV cache
# shifting is not supported for this context, disabling KV cache shifting" at
# startup. With shifting off and n_keep = 4, crossing the window has no graceful
# path -- the prompt is truncated from the FRONT, which is where the system
# prompt and the tool definitions live. An agent that has lost its tools still
# answers; it just answers uselessly. A 55K-token coding session against a 65536
# window was one exchange away from that, which is what prompted this.
export OLLAMA_CONTEXT_LENGTH=131072

if [ ! -d "$OLLAMA_MODELS" ]; then
    echo "OLLAMA_MODELS is unset or missing: '${OLLAMA_MODELS}'"
    exit 1
fi

set -e

echo "Pinning to GPUs ${CUDA_VISIBLE_DEVICES} on $(hostname)"
echo "Endpoint will be ${OLLAMA_HOST} on $(hostname)"
nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv

ollama serve
