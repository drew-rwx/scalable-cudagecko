#!/usr/bin/env bash

printf "~Multi-GPU~\n"
./bin/gpu_cuda_workflow -query test_data/myco.hyop.232.fasta -ref test_data/myco.hyop.7422.fasta
mv myco.hyop.232.fasta-myco.hyop.7422.fasta.csv multiGPU-frags.csv

printf "\n~Single-GPU~\n"
./bin/single_gpu_cuda_workflow -query test_data/myco.hyop.232.fasta -ref test_data/myco.hyop.7422.fasta
mv myco.hyop.232.fasta-myco.hyop.7422.fasta.csv singleGPU-frags.csv
