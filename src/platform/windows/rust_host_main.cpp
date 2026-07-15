#include "lumen_host.h"

int main(int argc, char *argv[]) {
  int exit_code;
  do {
    exit_code = lumen_host_run(argc, argv);
  } while (exit_code == 0 && lumen_host_take_restart_request());
  return exit_code;
}
