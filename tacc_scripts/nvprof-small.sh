#!/bin/bash

CUDA_BASELINE=0
CUDA_1_GPU=0
CUDA_2_GPU=0,1

BASELINE_BINARY=../bin/single_gpu_cuda_workflow
OUR_BINARY=../bin/gpu_cuda_workflow
#QUERY=lamprey.fa
QUERY=myco.hyop.232.fasta
REF=zebrafish.fa
QUERY_PATH=../test_data/$QUERY
REF_PATH=../test_data/$REF
#NSYS_PREPEND='nvprof --devices all -f'  # generates a report and sqlite
NSYS_PREPEND='nsys nvprof'  # generates a report and sqlite

#echo "~baseline~"
#export CUDA_VISIBLE_DEVICES=$CUDA_BASELINE
#$NSYS_PREPEND -o ../results/small-baseline.nvprof $BASELINE_BINARY -query $QUERY_PATH -ref $REF_PATH
#mv $QUERY-$REF.csv ../results/small-baseline.nvprof.csv

#echo "~1 GPU~"
#export CUDA_VISIBLE_DEVICES=$CUDA_1_GPU
#$NSYS_PREPEND -o ../results/small-1gpu.nvprof $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH
#mv "$QUERY-$REF.csv" ../results/small-1gpu.nvprof.csv

echo "~2 GPU~"
export CUDA_VISIBLE_DEVICES=$CUDA_2_GPU
#$NSYS_PREPEND -o ../results/small-2gpu.nvprof $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH
$OUR_BINARY -query $QUERY_PATH -ref $REF_PATH
#mv "$QUERY-$REF.csv" ../results/small-2gpu.nvprof.csv
