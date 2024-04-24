#!/bin/bash
#SBATCH -A ASC23013
#SBATCH -J nvprof-medium	# job name
#SBATCH -o nvprof-medium.%j   # name of the output and error file
#SBATCH -N 1                # total number of nodes requested
#SBATCH -n 1               # total number of tasks requested
#SBATCH -p gpu-a100              # queue name normal or development
<<<<<<< HEAD:tacc_scripts/nvprof-medium.sh
#SBATCH -t 00:45:00         # expected maximum runtime (hh:mm:ss)
=======
#SBATCH -t 00:30:00         # expected maximum runtime (hh:mm:ss)
>>>>>>> f8bb074775b95379a28ba81bfdbbd9057e802f91:tacc_scripts/nsys-medium.sh
#SBATCH --mail-user=api10@txstate.edu
#SBATCH --mail-type=all    # Send email at begin and end of job

#
# vars
#

CUDA_BASELINE=0
CUDA_1_GPU=0
CUDA_2_GPU=0,1
CUDA_3_GPU=0,1,2

RUNS=1  # just need one run

LOG_FILE_PREPEND=../scale-medium
BASELINE_BINARY=../bin/single_gpu_cuda_workflow
OUR_BINARY=../bin/gpu_cuda_workflow
QUERY=human.fa
REF=alligator.fa
QUERY_PATH=../test_data/$QUERY
REF_PATH=../test_data/$REF
<<<<<<< HEAD:tacc_scripts/nvprof-medium.sh
NVPROF_PATH=../temp.nvvp
NVPROF_PREPEND=nvprof --devices all -f -o $NVPROF_PATH
=======
NSYS_PREPEND = nsys nvprof  # generates a report and sqlite
NSYS_REPORT = ../report1.nsys-rep
NSYS_SQLITE = ../report1.sqlite
>>>>>>> f8bb074775b95379a28ba81bfdbbd9057e802f91:tacc_scripts/nsys-medium.sh

#
# run exp
#
date

echo "~baseline~"
export CUDA_VISIBLE_DEVICES=$CUDA_BASELINE
for (( i = 2; i <= $RUNS; i += 1 ))
do
<<<<<<< HEAD:tacc_scripts/nvprof-medium.sh
	$NVPROF_PREPEND $BASELINE_BINARY -query $QUERY_PATH -ref $REF_PATH -factor 0.05 > "$LOG_FILE_PREPEND.baseline.nvprof.log"
	mv $QUERY-$REF.csv ../results/medium-baseline.nvprof.csv
	mv $NVPROF_PATH ../results/medium-baseline.nvprof.nvvp
=======
	time $NSYS_PREPEND $BASELINE_BINARY -query $QUERY_PATH -ref $REF_PATH > "$LOG_FILE_PREPEND.baseline.nvprof.log"
	mv $QUERY-$REF.csv ../results/medium-baseline.nvprof.csv
  mv $NSYS_REPORT ../results/medium-baseline.nsys-rep
  mv $NSYS_SQLITE ../results/medium-baseline.sqlite
>>>>>>> f8bb074775b95379a28ba81bfdbbd9057e802f91:tacc_scripts/nsys-medium.sh
done

echo "~1 GPU~"
export CUDA_VISIBLE_DEVICES=$CUDA_1_GPU
for (( i = 2; i <= $RUNS; i += 1 ))
do
<<<<<<< HEAD:tacc_scripts/nvprof-medium.sh
	$NVPROF_PREPEND $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH -factor 0.05 > "$LOG_FILE_PREPEND.1gpu.nvprof.log"
=======
	time $NSYS_PREPEND $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH > "$LOG_FILE_PREPEND.1gpu.nvprof.log"
>>>>>>> f8bb074775b95379a28ba81bfdbbd9057e802f91:tacc_scripts/nsys-medium.sh
	mv "$QUERY-$REF.csv" ../results/medium-1gpu.nvprof.csv
	mv $NSYS_REPORT ../results/medium-1gpu.nsys-rep
  mv $NSYS_SQLITE ../results/medium-1gpu.sqlite
done

# echo "~2 GPU~"
# export CUDA_VISIBLE_DEVICES=$CUDA_2_GPU
# for (( i = 1; i <= $RUNS; i += 1 ))
# do
# 	time $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH > "$LOG_FILE_PREPEND.2gpu.log"
# 	mv "$QUERY-$REF.csv" ../results/medium-2gpu.csv
# done

echo "~3 GPU~"
export CUDA_VISIBLE_DEVICES=$CUDA_3_GPU
for (( i = 1; i <= $RUNS; i += 1 ))
do
<<<<<<< HEAD:tacc_scripts/nvprof-medium.sh
	$NVPROF_PREPEND $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH -factor 0.05 > "$LOG_FILE_PREPEND.3gpu.nvprof.log"
	mv "$QUERY-$REF.csv" ../results/medium-3gpu.nvprof.csv
	mv $NVPROF_PATH ../results/medium-3gpu.nvprof.nvvp
=======
	time $NSYS_PREPEND $OUR_BINARY -query $QUERY_PATH -ref $REF_PATH > "$LOG_FILE_PREPEND.3gpu.nvprof.log"
	mv "$QUERY-$REF.csv" ../results/medium-3gpu.nvprof.csv
  mv $NSYS_REPORT ../results/medium-3gpu.nvsys-rep
  mv $NSYS_SQLITE ../results/medium-3gpu.sqlite
>>>>>>> f8bb074775b95379a28ba81bfdbbd9057e802f91:tacc_scripts/nsys-medium.sh
done

date
