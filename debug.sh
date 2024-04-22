#!/usr/bin/env bash

cuda-gdb --args ./bin/gpu_cuda_workflow -query test_data/myco.hyop.232.fasta -ref test_data/myco.hyop.7422.fasta
