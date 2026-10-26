// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
#pragma once
#include <stdint.h>

#define RETRANS_EN

const unsigned DATA_WIDTH = 64 * 8;

const uint16_t MAX_QPS = 256;

const uint16_t PMTU = 4096;
const uint16_t PMTU_WORDS = PMTU / (DATA_WIDTH/8);

static const uint32_t PCIE_BATCH_PKG = 12;
static const uint32_t PCIE_BATCH_SIZE = PMTU * PCIE_BATCH_PKG;
