/**
 * @file src/main.h
 * @brief Declarations for the main entry point for Lumen.
 */
#pragma once

/**
 * @brief Main application entry point.
 * @param argc The number of arguments.
 * @param argv The arguments.
 * @examples
 * main(1, const char* args[] = {"sunshine", nullptr});
 * @examples_end
 */
int main(int argc, char *argv[]);

/**
 * @brief Options for running Lumen inside another host process.
 */
struct LumenRuntimeOptions {
  /**
   * @brief Whether the legacy native tray should be enabled.
   * Hosted macOS app flows should generally disable this and keep their own menu bar UI.
   */
  bool enable_legacy_system_tray;

  /**
   * @brief Whether process-level signal handlers should be installed.
   * Hosted app flows may want to manage their own lifecycle instead.
   */
  bool install_signal_handlers;
};

/**
 * @brief Start the Lumen runtime with explicit hosting options.
 * @param argc The number of arguments.
 * @param argv The arguments.
 * @param options Runtime hosting options.
 * @return Desired exit code after shutdown.
 */
int lumen_run(int argc, char *argv[], const LumenRuntimeOptions &options);

/**
 * @brief Request a graceful shutdown for a hosted Lumen runtime.
 * Does nothing if no hosted runtime is currently active.
 */
void lumen_request_shutdown(void);

/**
 * @brief Returns whether a hosted Lumen runtime is currently active.
 */
bool lumen_is_running(void);

/**
 * @brief Force-stop the currently running streamed application/session, if any.
 * Safe to call when no session is active.
 */
void lumen_force_stop_stream(void);
