#!/usr/bin/env bash

export CUDA_VISIBLE_DEVICES=0,1
./bin/gpu_cuda_workflow -query test_data/B.fa -ref test_data/A.fa
