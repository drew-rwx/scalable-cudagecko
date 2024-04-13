#!/bin/bash
#SBATCH -A ASC23013
#SBATCH -J exp	# job name
#SBATCH -o exp.%j   # name of the output and error file
#SBATCH -N 1                # total number of nodes requested
#SBATCH -n 1               # total number of tasks requested
#SBATCH -p gpu-a100-dev              # queue name normal or development
#SBATCH -t 00:45:00         # expected maximum runtime (hh:mm:ss)
#SBATCH --mail-user=api10@txstate.edu
#SBATCH --mail-type=all    # Send email at begin and end of job

date

#
# vars
#

RUNS=3

#
# speedup exp and scalability exp
#

export CUDA_VISIBLE_DEVICES=0
echo "baseline"
for (( i = 1; i <= $RUNS; i += 1 ))
do
done
echo "~~~"

export CUDA_VISIBLE_DEVICES=0
echo "multi-gpu: 1 GPU"
for (( i = 1; i <= $RUNS; i += 1 ))
do
done
echo "~~~"

export CUDA_VISIBLE_DEVICES=0,1
echo "multi-gpu: 2 GPU"
for (( i = 1; i <= $RUNS; i += 1 ))
do
done
echo "~~~"

export CUDA_VISIBLE_DEVICES=0,1,2
echo "multi-gpu: 3 GPU"
for (( i = 1; i <= $RUNS; i += 1 ))
do
done
echo "~~~"

date
