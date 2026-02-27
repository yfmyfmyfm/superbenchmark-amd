# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

"""Module of the ROCm memory performance benchmarks."""

import glob
import os
import re

from superbench.common.utils import logger
from superbench.benchmarks import BenchmarkRegistry, Platform, ReturnCode
from superbench.benchmarks.micro_benchmarks import MemBwBenchmark


class RocmMemBwBenchmark(MemBwBenchmark):
    """ROCm bandwidth test (rocm_bandwidth_test plugin --run tb ...) benchmark."""

    # Example lines:
    # Test 1:
    #  Executor: DMA 00 |   54.016 GB/s |    4.970 ms |    268435456 bytes | 54.911  GB/s (sum)
    #      Transfer 00  |   54.911 GB/s |    4.889 ms |    268435456 bytes | C0 -> D000:001 -> G0
    #  Aggregate (CPU)  |   53.532 GB/s |    5.014 ms |    268435456 bytes | Overhead: 0.045 ms

    re_test_start = re.compile(r"^Test\s+(\d+):\s*$")
    re_executor = re.compile(r"^\s*Executor:\s*(.+?)\|\s*([0-9.]+)\s*GB/s\s*\|")
    re_transfer = re.compile(r"^\s*Transfer\s+(\d+)\s*\|\s*([0-9.]+)\s*GB/s\s*\|.*?\|\s*(.+?)\s*$")
    re_aggregate = re.compile(r"^\s*Aggregate\s+\(CPU\)\s*\|\s*([0-9.]+)\s*GB/s\s*\|")

    def __init__(self, name, parameters=""):
        super().__init__(name, parameters)
        self._bin_name = "rocm_bandwidth_test"

    def add_parser_arguments(self):
        super().add_parser_arguments()

        self._parser.add_argument(
            "--tests",
            type=str,
            nargs="+",
            required=True,
            help=(
                "One or more test names matching hosttodevice-ce, hosttodevice-sm, "
                "devicetohost-ce, devicetohost-sm, etc. They must correspond to entries in the cfg."
            ),
        )

        self._parser.add_argument(
            "--use_cpu_aggregate",
            action="store_true",
            help="Use 'Aggregate (CPU)' GB/s instead of Transfer metrics.",
        )

    def _preprocess(self):
        if not super()._preprocess():
            return False

        if not self._set_binary_path() or not self._get_arguments_from_env():
            return False

        normalized_tests = [t.strip().lower() for t in self._args.tests if t.strip()]
        if not normalized_tests:
            logger.error("No tests specified for rocm memory bandwidth benchmark.")
            self._result.set_return_code(ReturnCode.INVALID_ARGUMENT)
            return False

        self._test_specs = []
        for test_name in normalized_tests:
            direction, tag = self._split_test_parts(test_name)
            if direction == "unknown" or tag == "unknown":
                logger.error(f"Unsupported test name '{test_name}'. Expect hosttodevice/devicetohost with ce/sm tag.")
                self._result.set_return_code(ReturnCode.INVALID_ARGUMENT)
                return False

            cfg_path = self._resolve_cfg_path(direction, tag)
            if cfg_path is None:
                logger.error(f"cfg file for test '{test_name}' not found under {self._args.bin_dir}.")
                self._result.set_return_code(ReturnCode.INVALID_ARGUMENT)
                return False

            command = os.path.join(self._args.bin_dir, self._bin_name) + f" plugin --run tb {cfg_path}"
            self._commands.append(command)
            self._test_specs.append(
                {
                    "name": test_name,
                    "direction": direction,
                    "tag": tag,
                    "cfg": cfg_path,
                }
            )

        return True

    def _process_raw_result(self, cmd_idx, raw_output):
        try:
            test_spec = self._test_specs[cmd_idx]
            self._result.add_raw_data(
                f"raw_output_{test_spec['name']}", raw_output, self._args.log_raw_data
            )

            per_test = {}
            current_test = None

            for line in raw_output.splitlines():
                line = line.rstrip("\n")

                m = self.re_test_start.match(line.strip())
                if m:
                    current_test = int(m.group(1))
                    per_test[current_test] = {'lanes': []}
                    continue

                if current_test is None:
                    continue

                m = self.re_executor.match(line)
                if m:
                    per_test[current_test]["executor_gbps"] = float(m.group(2))
                    continue

                m = self.re_transfer.match(line)
                if m:
                    transfer_id = int(m.group(1))
                    gbps = float(m.group(2))
                    lane_info = {
                        "id": transfer_id,
                        "gbps": gbps,
                    }
                    cpu_idx, gpu_idx = self._parse_topology(m.group(3), test_spec["direction"])
                    if cpu_idx is not None:
                        lane_info["cpu"] = cpu_idx
                    if gpu_idx is not None:
                        lane_info["gpu"] = gpu_idx
                    per_test[current_test].setdefault("lanes", []).append(lane_info)
                    continue

                m = self.re_aggregate.match(line)
                if m:
                    per_test[current_test]["cpu_gbps"] = float(m.group(1))
                    continue

            if not per_test:
                self._result.add_raw_data("rocm_bandwidth_test", "No tests found", self._args.log_raw_data)
                self._result.set_return_code(ReturnCode.MICROBENCHMARK_RESULT_PARSING_FAILURE)
                return False

            values, lane_records = self._collect_measurements(per_test, use_cpu=self._args.use_cpu_aggregate)
            if not values:
                self._result.set_return_code(ReturnCode.MICROBENCHMARK_RESULT_PARSING_FAILURE)
                return False

            metric_name = self._build_metric_name(test_spec["direction"], test_spec["tag"])
            agg = self._median(values)
            total = sum(values)
            self._result.add_result(metric_name, float(agg))
            self._result.add_result(f"{metric_name}_sum", float(total))
            for idx, value in enumerate(values, start=1):
                self._result.add_result(f"{metric_name}_test{idx}", float(value))

            if lane_records:
                for lane in lane_records:
                    cpu_idx = lane.get("cpu")
                    gpu_idx = lane.get("gpu")
                    if cpu_idx is None or gpu_idx is None:
                        continue
                    metric_lane = f"{metric_name}_cpu{cpu_idx}_gpu{gpu_idx}_bw"
                    self._result.add_result(metric_lane, float(lane["gbps"]))

            self._result.set_return_code(ReturnCode.SUCCESS)
            return True

        except Exception as e:
            logger.error(
                f"The result format is invalid - round: {self._curr_run_index}, "
                f"benchmark: {self._name}, message: {str(e)}."
            )
            self._result.add_result("abort", 1)
            self._result.set_return_code(ReturnCode.MICROBENCHMARK_RESULT_PARSING_FAILURE)
            return False

    @staticmethod
    def _split_test_parts(test_name):
        direction = "unknown"
        tag = "unknown"
        if "hosttodevice" in test_name or "h2d" in test_name:
            direction = "h2d"
        elif "devicetohost" in test_name or "d2h" in test_name:
            direction = "d2h"

        if "-ce" in test_name or "_ce" in test_name:
            tag = "ce"
        elif "-sm" in test_name or "_sm" in test_name:
            tag = "sm"

        return direction, tag

    def _collect_measurements(self, per_test, use_cpu=False):
        values = []
        lane_records = []
        for test_id in sorted(per_test.keys()):
            details = per_test[test_id]
            if use_cpu and "cpu_gbps" in details:
                values.append(details["cpu_gbps"])
                continue

            lanes = details.get("lanes", [])
            if lanes:
                primary_lane = self._select_lane(lanes)
                if primary_lane is not None:
                    values.append(primary_lane["gbps"])
                lane_records.extend(lanes)
                continue

            if "executor_gbps" in details:
                values.append(details["executor_gbps"])

        return values, (lane_records if not use_cpu else [])

    @staticmethod
    def _build_metric_name(direction, tag):
        if direction == "h2d":
            base = "host_to_device_memcpy"
        elif direction == "d2h":
            base = "device_to_host_memcpy"
        else:
            base = "memcpy"

        return f"{base}_{tag}"

    @staticmethod
    def _median(values):
        values_sorted = sorted(values)
        mid = len(values_sorted) // 2
        if len(values_sorted) % 2 == 1:
            return values_sorted[mid]
        return 0.5 * (values_sorted[mid - 1] + values_sorted[mid])

    @staticmethod
    def _select_lane(lanes):
        lane0 = next((lane for lane in lanes if lane.get("id") == 0), None)
        if lane0 is not None:
            return lane0
        if lanes:
            return max(lanes, key=lambda lane: lane.get("gbps", 0.0))
        return None

    @staticmethod
    def _parse_topology(path_str, direction):
        cpu_matches = re.findall(r"C(\d+)", path_str)
        gpu_matches = re.findall(r"G(\d+)", path_str)

        cpu_idx = None
        gpu_idx = None

        if direction == "h2d":
            if cpu_matches:
                cpu_idx = int(cpu_matches[0])
            if gpu_matches:
                gpu_idx = int(gpu_matches[-1])
        elif direction == "d2h":
            if cpu_matches:
                cpu_idx = int(cpu_matches[-1])
            if gpu_matches:
                gpu_idx = int(gpu_matches[0])
        else:
            if cpu_matches:
                cpu_idx = int(cpu_matches[0])
            if gpu_matches:
                gpu_idx = int(gpu_matches[-1])

        return cpu_idx, gpu_idx

    def _resolve_cfg_path(self, direction, tag):
        prefix = "h2d" if direction == "h2d" else "d2h"
        base_pattern = f"{prefix}_{tag}"
        candidate_patterns = [
            f"{base_pattern}.cfg",
            f"{base_pattern}_*.cfg",
        ]

        for pattern in candidate_patterns:
            matches = sorted(glob.glob(os.path.join(self._args.bin_dir, pattern)))
            if matches:
                return matches[0]
        return None


BenchmarkRegistry.register_benchmark('mem-bw', RocmMemBwBenchmark, platform=Platform.ROCM)
