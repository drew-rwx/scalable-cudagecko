#!/usr/bin/env bash

./bin/gpu_cuda_workflow -query test_data/GCF_protein.faa -ref test_data/GCA_protein.faa
mv GCF_protein.faa-GCA_protein.faa.csv multiGPU-frags.csv

./bin/single_gpu_cuda_workflow -query test_data/GCF_protein.faa -ref test_data/GCA_protein.faa
mv GCF_protein.faa-GCA_protein.faa.csv singleGPU-frags.csv