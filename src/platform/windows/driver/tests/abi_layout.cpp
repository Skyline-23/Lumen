#include "lumen_driver_abi.h"

#include <cstddef>
#include <iostream>

static_assert(offsetof(LumenDriverCoreRequest, owner_id) == 16);
static_assert(offsetof(LumenDriverCoreRequest, generation) == 24);
static_assert(offsetof(LumenDriverCoreRequest, request_id) == 32);
static_assert(offsetof(LumenDriverCoreRequest, arguments) == 40);
static_assert(offsetof(LumenDriverCoreResponse, generation) == 24);
static_assert(offsetof(LumenDriverCoreState, pending_access_unit_reads) == 24);
static_assert(offsetof(LumenDriverCoreState, pending_event_reads) == 56);
static_assert(LUMEN_IOCTL_QUERY_CAPABILITIES == 0x00226400u);
static_assert(LUMEN_IOCTL_DEQUEUE_ACCESS_UNIT == 0x0022E422u);
static_assert(LUMEN_IOCTL_DEQUEUE_EVENT == 0x0022E426u);

int main() {
  std::cout << "{\"abi_layout\":\"ok\",\"request_size\":"
            << sizeof(LumenDriverCoreRequest) << ",\"response_size\":"
            << sizeof(LumenDriverCoreResponse) << ",\"state_size\":"
            << sizeof(LumenDriverCoreState) << "}\n";
  return 0;
}
