#!/usr/bin/env bash

RUNS=5

echo "Exp; Comparing one run of singleGPU to one run of singleGPU"
for (( i = 1; i <= $RUNS; i++ ))
do
	echo "run $i"
	
	./bin/single_gpu_cuda_workflow -query test_data/GCF_protein.faa -ref test_data/GCA_protein.faa > /dev/null 2>&1
	mv GCF_protein.faa-GCA_protein.faa.csv singleGPU-frags.csv1
	./bin/single_gpu_cuda_workflow -query test_data/GCF_protein.faa -ref test_data/GCA_protein.faa > /dev/null 2>&1
	mv GCF_protein.faa-GCA_protein.faa.csv singleGPU-frags.csv2

	./compare.py singleGPU-frags.csv1 singleGPU-frags.csv2
done


echo "Exp; Comparing one run of multiGPU to one run of singleGPU"
for (( i = 1; i <= $RUNS; i++ ))
do
	echo "run $i"
	./crun.sh > /dev/null 2>&1
	./compare.py multiGPU-frags.csv singleGPU-frags.csv
done