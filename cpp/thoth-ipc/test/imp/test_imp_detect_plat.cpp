
#include "../archive/test.h"

#include "thoth-ipc/imp/detect_plat.h"

TEST(detect_plat, os) {
#if defined(THOTH_IPC_OS_WINCE)
  std::cout << "THOTH_IPC_OS_WINCE\n";
#elif defined(THOTH_IPC_OS_WIN)
  std::cout << "THOTH_IPC_OS_WIN\n";
#elif defined(THOTH_IPC_OS_LINUX)
  std::cout << "THOTH_IPC_OS_LINUX\n";
#elif defined(THOTH_IPC_OS_QNX)
  std::cout << "THOTH_IPC_OS_QNX\n";
#elif defined(THOTH_IPC_OS_ANDROID)
  std::cout << "THOTH_IPC_OS_ANDROID\n";
#elif defined(THOTH_IPC_OS_APPLE)
  std::cout << "THOTH_IPC_OS_APPLE\n";
#elif defined(THOTH_IPC_OS_FREEBSD)
  std::cout << "THOTH_IPC_OS_FREEBSD\n";
#else
  ASSERT_TRUE(false);
#endif
  SUCCEED();
}

TEST(detect_plat, cc) {
#if defined(THOTH_IPC_CC_MSVC)
  std::cout << "THOTH_IPC_CC_MSVC\n";
#elif defined(THOTH_IPC_CC_GNUC)
  std::cout << "THOTH_IPC_CC_GNUC\n";
#else
  ASSERT_TRUE(false);
#endif
  SUCCEED();
}

TEST(detect_plat, cpp) {
#if defined(THOTH_IPC_CPP_20)
  std::cout << "THOTH_IPC_CPP_20\n";
#elif defined(THOTH_IPC_CPP_17)
  std::cout << "THOTH_IPC_CPP_17\n";
#elif defined(THOTH_IPC_CPP_14)
  std::cout << "THOTH_IPC_CPP_14\n";
#else
  ASSERT_TRUE(false);
#endif
  SUCCEED();
}

TEST(detect_plat, byte_order) {
  auto is_endian_little = [] {
    union {
      std::int32_t a;
      std::int8_t  b;
    } c;
    c.a = 1;
    return c.b == 1;
  };
  EXPECT_EQ(!!THOTH_IPC_ENDIAN_LIT, is_endian_little());
  EXPECT_NE(!!THOTH_IPC_ENDIAN_BIG, is_endian_little());
}

TEST(detect_plat, fallthrough) {
  switch (0) {
  case 0:
    std::cout << "fallthrough 0\n";
    THOTH_IPC_FALLTHROUGH;
  case 1:
    std::cout << "fallthrough 1\n";
    THOTH_IPC_FALLTHROUGH;
  default:
    std::cout << "fallthrough default\n";
    break;
  }
  SUCCEED();
}

TEST(detect_plat, unused) {
  THOTH_IPC_UNUSED int abc;
  SUCCEED();
}

TEST(detect_plat, likely_unlikely) {
  int xx = sizeof(int);
  if THOTH_IPC_LIKELY(xx < sizeof(long long)) {
    std::cout << "sizeof(int) < sizeof(long long)\n";
  } else if THOTH_IPC_UNLIKELY(xx < sizeof(char)) {
    std::cout << "sizeof(int) < sizeof(char)\n";
  } else {
    std::cout << "sizeof(int) < whatever\n";
  }
  SUCCEED();
}
