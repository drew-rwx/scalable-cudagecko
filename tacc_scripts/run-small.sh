#!/bin/bash
#SBATCH -A ASC23013
#SBATCH -J scale-small	# job name
#SBATCH -o scale-small.%j   # name of the output and error file
#SBATCH -N 1                # total number of nodes requested
#SBATCH -n 1               # total number of tasks requested
#SBATCH -p gpu-a100              # queue name normal or development
#SBATCH -t 01:35:00         # expected maximum runtime (hh:mm:ss)
#SBATCH --mail-user=api10@txstate.edu
#SBATCH --mail-type=all    # Send email at begin and end of job

#
# vars
#

CUDA_BASELINE=0
CUDA_1_GPU=0
CUDA_2_GPU=0,1
CUDA_3_GPU=0,1,2

RUNS=3

LOG_FILE_PREPEND=../scale-small
BASELINE_BINARY=../bin/single_gpu_cuda_workflow
OUR_BINARY=../bin/gpu_cuda_workflow
QUERY=myco.hyop.232.fasta
REF=myco.hyop.7422.fasta
QUERY_PATH=../test_data/$QUERY
REF_PATH=../test_data/$REF

#
# run exp
#
date

echo "~baseline~"
export CUDA_VISIBLE_DEVICES=$CUDA_BASELINE
for (( i = 1; i <= $RUNS; i += 1 ))
do
	time $BASELINE_BINARY -query $QUERY_PATH -ref $REF_PATH > "$LOG_FILE_PREPEND.baseline.log"
	mv $QUERY-$REF.csv ../results/small-baseline.csv
done

echo "~1 GPU~"
export CUDA_VISIBLE_DEVICES=$CUDA_1_GPU
for (( i = 1; i <= $RUNS; i += 1 ))
do
	time $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH > "$LOG_FILE_PREPEND.1gpu.log"
	mv "$QUERY-$REF.csv" ../results/small-1gpu.csv
done

echo "~2 GPU~"
export CUDA_VISIBLE_DEVICES=$CUDA_2_GPU
for (( i = 1; i <= $RUNS; i += 1 ))
do
	time $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH > "$LOG_FILE_PREPEND.2gpu.log"
	mv "$QUERY-$REF.csv" ../results/small-2gpu.csv
done

echo "~3 GPU~"
export CUDA_VISIBLE_DEVICES=$CUDA_3_GPU
for (( i = 1; i <= $RUNS; i += 1 ))
do
	time $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH > "$LOG_FILE_PREPEND.3gpu.log"
	mv "$QUERY-$REF.csv" ../results/small-3gpu.csv
done

date