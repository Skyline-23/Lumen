#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

#include "platform/macos/tray_notifications.h"

#include <atomic>
#include <string>

namespace {
  constexpr const char *notification_url_key = "apolloLaunchPath";
  std::atomic<bool> authorization_requested {false};

  NSString *to_ns_string(std::string_view value) {
    if (value.empty()) {
      return @"";
    }

    return [[NSString alloc] initWithBytes:value.data()
                                    length:value.size()
                                  encoding:NSUTF8StringEncoding] ?: @"";
  }

  void request_notification_authorization_if_needed() {
    bool expected = false;
    if (!authorization_requested.compare_exchange_strong(expected, true, std::memory_order_relaxed)) {
      return;
    }

    [[UNUserNotificationCenter currentNotificationCenter]
      requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                    completionHandler:^(__unused BOOL granted, __unused NSError *error) {
                    }];
  }
}

namespace platf {
  void post_macos_tray_notification(
    std::string_view identifier,
    std::string_view title,
    std::string_view body,
    std::string_view launch_path
  ) {
    request_notification_authorization_if_needed();

    NSString *identifier_string = to_ns_string(identifier);
    NSString *title_string = to_ns_string(title);
    NSString *body_string = to_ns_string(body);
    NSString *launch_path_string = to_ns_string(launch_path);

    dispatch_async(dispatch_get_main_queue(), ^{
      UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
      content.title = title_string;
      content.body = body_string;
      if (launch_path_string.length > 0) {
        content.userInfo = @{ @(notification_url_key): launch_path_string };
      }

      UNNotificationRequest *request =
        [UNNotificationRequest requestWithIdentifier:identifier_string
                                             content:content
                                             trigger:nil];
      [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request
         withCompletionHandler:^(__unused NSError *error) {
         }];
    });
  }
}
