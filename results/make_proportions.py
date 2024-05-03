#!/usr/bin/env python3

import matplotlib.pyplot as plt
import numpy as np


def append_misc(arr):
    arr.append(1.0 - sum(arr))


def draw_pie(labels, values, base_filename):
    fix, ax = plt.subplots()
    ax.pie(values, labels=labels, autopct="%1.2f%%")
    plt.tight_layout()
    plt.savefig(f"prop_{base_filename}.png")
    plt.savefig(f"prop-{base_filename}.pdf")


categories_api = [
    "cudaDeviceSynchronize",
    "cudaHostAlloc",
    "cudaFreeHost",
    "cudaMemcpy",
    "Misc.",
]
categories_gpu = [
    "moderngpu mergesort",  # the mangled kernel names
    "CUDA memset",
    "CUDA memcpy HtoD",
    "kernel_index_global32",
    "kernel_hits_load_balancing",
    # "CUDA memcpy DtoH",
    "Misc.",
]

baseline_api = [0.4738, 0.3463, 0.1043, 0.0427]
baseline_gpu = [0.6593, 0.1579, 0.0818, 0.0636, 0.0178]

# note: very similar to baseline, just gonna skip
# ours1gpu_api = [0.4865, 0.3551, 0.1068, 0.0438]
# ours1gpu_gpu = [0.6588, 0.1575, 0.0816, 0.0645, 0.0179, 0.0150]

ours2gpu_api = [0.3580, 0.4550, 0.1366, 0.0331]
ours2gpu_gpu1 = [0.6381, 0.1493, 0.0961, 0.0624, 0.0172]
ours2gpu_gpu2 = [0.6802, 0.1743, 0.0688, 0.0590, 0.0172]

append_misc(baseline_api)
append_misc(ours2gpu_api)
append_misc(baseline_gpu)
append_misc(ours2gpu_gpu1)
append_misc(ours2gpu_gpu2)

width = 0.8

#
# api graph
#

bar_labels = ["Baseline", "2 GPU (ours)"]
data_reorganized = {}
for i in range(len(categories_api)):
    data_reorganized[categories_api[i]] = [baseline_api[i], ours2gpu_api[i]]

fig, ax = plt.subplots(figsize=(5, 4))
ax.yaxis.grid(True, linestyle="--", linewidth=0.5)
ax.set_axisbelow(True)

bottom = np.zeros(len(bar_labels))
for category, proportions in data_reorganized.items():
    p = ax.bar(
        bar_labels, proportions, width, label=category, bottom=bottom, edgecolor="black"
    )
    bottom += proportions

ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.1), ncol=2)

plt.tight_layout()
plt.savefig(f"api_proportions.pdf")

#
# kernel graph
#

bar_labels = ["Baseline", "Ours, GPU1", "Ours, GPU2"]
data_reorganized = {}
for i in range(len(categories_gpu)):
    data_reorganized[categories_gpu[i]] = [
        baseline_gpu[i],
        ours2gpu_gpu1[i],
        ours2gpu_gpu2[i],
    ]

fig, ax = plt.subplots(figsize=(5, 4))
ax.yaxis.grid(True, linestyle="--", linewidth=0.5)
ax.set_axisbelow(True)

bottom = np.zeros(len(bar_labels))
for category, proportions in data_reorganized.items():
    p = ax.bar(
        bar_labels, proportions, width, label=category, bottom=bottom, edgecolor="black"
    )
    bottom += proportions

ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.1), ncol=2)

plt.tight_layout()
plt.savefig(f"kernel_proportions.pdf")
