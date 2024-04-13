#!/usr/bin/env bash

printf "~Multi-GPU~\n"
./bin/gpu_cuda_workflow -query test_data/B.fa -ref test_data/A.fa
mv B.fa-A.fa.csv multiGPU-frags.csv

printf "\n~Single-GPU~\n"
./bin/single_gpu_cuda_workflow -query test_data/B.fa -ref test_data/A.fa
mv B.fa-A.fa.csv singleGPU-frags.csv
