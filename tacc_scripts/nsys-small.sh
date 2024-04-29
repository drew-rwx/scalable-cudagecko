#!/bin/bash
#SBATCH -A ASC23013
#SBATCH -J nvprof-small	# job name
#SBATCH -o nvprof-small.%j   # name of the output and error file
#SBATCH -N 1                # total number of nodes requested
#SBATCH -n 1               # total number of tasks requested
#SBATCH -p gpu-a100              # queue name normal or development
#SBATCH -t 00:40:00         # expected maximum runtime (hh:mm:ss)
#SBATCH --mail-user=bab334@txstate.edu
#SBATCH --mail-type=all    # Send email at begin and end of job

#
# vars
#

CUDA_BASELINE=0
CUDA_1_GPU=0
CUDA_2_GPU=0,1
CUDA_3_GPU=0,1,2

RUNS=1  # just need one run

LOG_FILE_PREPEND=../nsys-small
BASELINE_BINARY=../bin/single_gpu_cuda_workflow
OUR_BINARY=../bin/gpu_cuda_workflow
QUERY=lamprey.fa
REF=zebrafish.fa
QUERY_PATH=../test_data/$QUERY
REF_PATH=../test_data/$REF
NSYS_PREPEND='nsys nvprof'  # generates a report and sqlite
NSYS_REPORT=./report1.nsys-rep
NSYS_SQLITE=./report1.sqlite

#
# run exp
#
date

echo "~baseline~"
export CUDA_VISIBLE_DEVICES=$CUDA_BASELINE
for (( i = 1; i <= $RUNS; i += 1 ))
do
	$NSYS_PREPEND $BASELINE_BINARY -query $QUERY_PATH -ref $REF_PATH
	mv $QUERY-$REF.csv ../results/small-baseline.nvprof.csv
  mv $NSYS_REPORT ../results/small-baseline.nsys-rep
  mv $NSYS_SQLITE ../results/small-baseline.sqlite
done

echo "~1 GPU~"
export CUDA_VISIBLE_DEVICES=$CUDA_1_GPU
for (( i = 1; i <= $RUNS; i += 1 ))
do
	$NSYS_PREPEND $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH
	mv "$QUERY-$REF.csv" ../results/small-1gpu.nvprof.csv
	mv $NSYS_REPORT ../results/small-1gpu.nsys-rep
  mv $NSYS_SQLITE ../results/small-1gpu.sqlite
done

# echo "~2 GPU~"
# export CUDA_VISIBLE_DEVICES=$CUDA_2_GPU
# for (( i = 1; i <= $RUNS; i += 1 ))
# do
# 	time $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH
# 	mv "$QUERY-$REF.csv" ../results/small-2gpu.csv
# done

echo "~3 GPU~"
export CUDA_VISIBLE_DEVICES=$CUDA_3_GPU
for (( i = 1; i <= $RUNS; i += 1 ))
do
	$NSYS_PREPEND $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH
	mv "$QUERY-$REF.csv" ../results/small-3gpu.nvprof.csv
  mv $NSYS_REPORT ../results/small-3gpu.nsys-rep
  mv $NSYS_SQLITE ../results/small-3gpu.sqlite
done

date
