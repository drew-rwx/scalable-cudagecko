#!/usr/bin/env python3

import matplotlib.pyplot as plt
import matplotlib.lines as lines
import numpy as np
import statistics

# constants
RUNS = 3
MAX_GPUS = 3
BYTE_COUNTS = {
    "small": 1153241457 * 1712826111,
    "medium": 3273481150 * 2217921712,
    "large": 3273481150 * 3105893940,
}


all_times = {"small": [], "medium": [], "large": []}


def read_my_file(file):
    with open(file, "r") as fin:
        data = fin.read()
        return data


def write_my_file(file, data):
    # make data writable
    write_data = []
    for d in data:
        write_data.append(str(d) + "\n")

    # write the data
    with open(file, "w") as fout:
        fout.writelines(write_data)


for size in BYTE_COUNTS.keys():
    # setting up data

    data = read_my_file(f"../tacc_scripts/{size}.out")
    data = data.split("~~~")

    baseline_data = data[0]
    baseline_data = baseline_data.splitlines()
    baseline_times = []

    for r in range(RUNS):
        time = baseline_data[r * 3]
        time = time.split()[-1]
        m, _, s = time.partition("m")
        s = s[0:-1]

        m = float(m) * 60
        s = float(s)

        time = m + s
        baseline_times.append(time)

    baseline_time = statistics.mean(baseline_times)
    print(f"Baseline run time (s): {baseline_time:.2f}")

    gpu_1_data = data[1]
    gpu_1_data = gpu_1_data.splitlines()
    gpu_1_data = gpu_1_data[1:]
    gpu_1_times = []

    for r in range(RUNS):
        time = gpu_1_data[r * 3]
        time = time.split()[-1]
        m, _, s = time.partition("m")
        s = s[0:-1]

        m = float(m) * 60
        s = float(s)

        time = m + s
        gpu_1_times.append(time)

    gpu_1_time = statistics.mean(gpu_1_times)
    print(f"1 GPU run time (s): {gpu_1_time:.2f}")

    gpu_2_data = data[2]
    gpu_2_data = gpu_2_data.splitlines()
    gpu_2_data = gpu_2_data[1:]
    gpu_2_times = []

    for r in range(RUNS):
        time = gpu_2_data[r * 3]
        time = time.split()[-1]
        m, _, s = time.partition("m")
        s = s[0:-1]

        m = float(m) * 60
        s = float(s)

        time = m + s
        gpu_2_times.append(time)

    gpu_2_time = statistics.mean(gpu_2_times)
    print(f"2 GPU run time (s): {gpu_2_time:.2f}")

    gpu_3_data = data[3]
    gpu_3_data = gpu_3_data.splitlines()
    gpu_3_data = gpu_3_data[1:]
    gpu_3_times = []

    for r in range(RUNS):
        time = gpu_3_data[r * 3]
        time = time.split()[-1]
        m, _, s = time.partition("m")
        s = s[0:-1]

        m = float(m) * 60
        s = float(s)

        time = m + s
        gpu_3_times.append(time)

    gpu_3_time = statistics.mean(gpu_3_times)
    print(f"3 GPU run time (s): {gpu_3_time:.2f}")

    all_times[size] = [gpu_1_time, gpu_2_time, gpu_3_time]

    #
    # make figures
    #

    SHOW_FIGURES = False
    BLOCK_ON_SHOW = False

    # throughput

    # set font
    # plt.rcParams["font.family"] = "serif"
    # plt.rcParams["font.serif"] = ["CMU Serif"]

    fig, ax = plt.subplots(figsize=(4, 4))

    baseline_thp = BYTE_COUNTS[size] / baseline_time / 1000 / 1000 / 1000 / 1000 / 1000
    gpu_1_thp = BYTE_COUNTS[size] / gpu_1_time / 1000 / 1000 / 1000 / 1000 / 1000
    gpu_2_thp = BYTE_COUNTS[size] / gpu_2_time / 1000 / 1000 / 1000 / 1000 / 1000
    gpu_3_thp = BYTE_COUNTS[size] / gpu_3_time / 1000 / 1000 / 1000 / 1000 / 1000

    print(f"Baseline: {baseline_thp:.2f} Peta-monomers/s")
    print(f"1 GPU: {gpu_1_thp:.2f} Peta-monomers/s")
    print(f"2 GPU: {gpu_2_thp:.2f} Peta-monomers/s")
    print(f"3 GPU: {gpu_3_thp:.2f} Peta-monomers/s")

    bar_names = ["Baseline", "1 GPU", "2 GPUs", "3 GPUs"]
    throughputs = [baseline_thp, gpu_1_thp, gpu_2_thp, gpu_3_thp]
    labels = ["Baseline", "Ours", "_Ours", "_Ours"]  # for legend
    colors = ["red", "blue", "blue", "blue"]
    bar_width = 0.8

    ax.bar(
        bar_names, throughputs, bar_width, label=labels, color=colors, edgecolor="black"
    )
    # ax.bar(1, baseline_thp, 0.2, label="Baseline", color="red")
    # ax.bar(2, gpu_1_thp, 0.2, label="Ours", color="blue")
    # ax.bar(3, gpu_2_thp, 0.2, label="Ours", color="blue")
    # ax.bar(4, gpu_3_thp, 0.2, label="Ours", color="blue")

    plt.yticks(range(0, 50 + 1, 10))

    # ax.set_xlabel("Program Version", fontsize=12)
    ax.set_ylabel("Throughput (Peta-monomers/s)", fontsize=15)

    # y: size of numbers, x: remove ticks
    ax.tick_params(axis="y", labelsize=15)
    # ax.tick_params(axis="x", length=0, labelsize=0)

    # legend
    ax.legend(loc="upper left")

    # grid lines
    ax.yaxis.grid(True, linestyle="--", linewidth=0.5)
    ax.set_axisbelow(True)

    # title
    # plt.title(f"Throughput, {size} inputs")

    plt.tight_layout()
    plt.savefig(f"../figures/throughput-{size}.pdf")
    plt.savefig(f"../figures/throughput-{size}.png")
    if SHOW_FIGURES:
        plt.show(block=BLOCK_ON_SHOW)

#
# speedup
#

# set font
# plt.rcParams["font.family"] = "serif"
# plt.rcParams["font.serif"] = ["CMU Serif"]

fig, ax = plt.subplots(figsize=(2.5, 2.5))

ax.plot([0, 1, 2, 3, 4], [0, 1, 2, 3, 4], 0.2, color="black", linestyle="dotted")

for size in all_times.keys():
    gpu_1_time = all_times[size][0]
    gpu_2_time = all_times[size][1]
    gpu_3_time = all_times[size][2]

    ax.plot(
        [1, 2, 3],
        [gpu_1_time / gpu_1_time, gpu_1_time / gpu_2_time, gpu_1_time / gpu_3_time],
        linewidth=2.5,
        label=size,
        marker=".",
    )

plt.xticks(np.arange(1, MAX_GPUS + 1, 1))
plt.yticks(np.arange(1, 3.1, 1))

plt.xlim(0.75, MAX_GPUS + 0.25)
plt.ylim(0.75, 3.1)

ax.set_xlabel("Number of GPUs")
ax.set_ylabel("Speedup")

ax.tick_params(axis="y")
ax.tick_params(axis="x")

# grid lines
ax.yaxis.grid(True, linestyle="--", linewidth=0.5)
ax.xaxis.grid(True, linestyle="--", linewidth=0.5)
ax.set_axisbelow(True)

# legend
ax.legend(loc="upper left")

# title
# plt.title(f"Speedup—{size}")

plt.tight_layout()
if SHOW_FIGURES:
    plt.show(block=BLOCK_ON_SHOW)
plt.savefig(f"../figures/speedup.pdf")
plt.savefig(f"../figures/speedup.png")

# wait for input to show the figures
if SHOW_FIGURES:
    input()
