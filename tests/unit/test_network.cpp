/**
 * @file tests/unit/test_network.cpp
 * @brief Test src/network.*
 */
#include "../tests_common.h"

#include <src/network.h>

struct MdnsInstanceNameTest: testing::TestWithParam<std::tuple<std::string, std::string>> {};

TEST_P(MdnsInstanceNameTest, Run) {
  auto [input, expected] = GetParam();
  ASSERT_EQ(net::mdns_instance_name(input), expected);
}

TEST(ParseAddressTest, RejectsInvalidInputWithoutThrowing) {
  EXPECT_FALSE(net::parse_address("").has_value());
  EXPECT_FALSE(net::parse_address("not-an-address").has_value());
}

TEST(ParseAddressTest, NormalizesIPv4MappedIPv6Addresses) {
  auto parsed = net::parse_address("::ffff:192.168.10.24");
  ASSERT_TRUE(parsed.has_value());
  EXPECT_TRUE(parsed->is_v4());
  EXPECT_EQ(parsed->to_string(), "192.168.10.24");
}

INSTANTIATE_TEST_SUITE_P(
  MdnsInstanceNameTests,
  MdnsInstanceNameTest,
  testing::Values(
    std::make_tuple("shortname-123", "shortname-123"),
    std::make_tuple("space 123", "space-123"),
    std::make_tuple("hostname.domain.test", "hostname"),
    std::make_tuple("&", "Sunshine"),
    std::make_tuple("", "Sunshine"),
    std::make_tuple("😁", "Sunshine"),
    std::make_tuple(std::string(128, 'a'), std::string(63, 'a'))
  )
);
